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
	Served := Map(
		LayoutRegistry_RawUrl("index.json"), Map("status", 200, "body", _LCT_Read(_LCT_RegistryDir() . "index.json"),
			"etag", Etag),
		LayoutRegistry_RawUrl("ergol/ergol.keylayout"), Map("status", 200, "body", LayoutText, "etag", "")
	)
	for Item in LayoutCatalogue_Entry(_LCT_Index(), "ergol")["extension"]["files"] {
		Url := LayoutRegistry_RawUrl(Item["file"])
		if !Served.Has(Url)
			Served[Url] := Map("status", 200, "body", _LCT_Read(_LCT_RegistryDir() . StrReplace(Item["file"], "/", "\")), "etag", "")
	}
	return Served
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
	LayoutCatalogue_Install(Id, Dir, (Args*) => Results.Push(Args), Transport, Bundled, BundledDir, false)
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

Test("layout catalogue: a source checkout refreshes locally without HTTP or cache writes (layout-catalogue-local)",
	_LCT_LocalRefreshCase)

_LCT_LocalRefreshCase() {
	Dir := _LCT_TempDir()
	try {
		Cache := '{"layouts":[]}'
		_LCT_WriteRaw(Dir . "index.json", Cache)
		for Bundled in [_LCT_Index(), 0] {
			Log := [], Outcomes := []
			LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome), _LCT_Transport(Map(), Log), Bundled)
			AssertEqual(1, Outcomes.Length, "local refresh completes once")
			AssertEqual(0, Log.Length, "unpublished checkout data must not trigger a remote request")
			AssertEqual(Cache, _LCT_Read(Dir . "index.json"), "local refresh preserves remote cache")
			if (Bundled is Map) {
				AssertEqual("bundled", Outcomes[1]["source"])
				AssertEqual(Bundled, Outcomes[1]["index"])
				AssertEqual(0, Outcomes[1]["error"])
			} else {
				AssertEqual("none", Outcomes[1]["source"])
				AssertEqual("invalid_index", Outcomes[1]["error"]["code"])
			}
		}
	} finally DirDelete(Dir, true)
}

_LCT_RefreshCase() {
	Dir := _LCT_TempDir()
	try {
		Log := []
		Outcomes := []
		LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome),
			_LCT_Transport(_LCT_Served(_LCT_LayoutText("ergol")), Log), 0, false)
		AssertEqual(1, Outcomes.Length)
		AssertEqual("network", Outcomes[1]["source"])
		AssertEqual(_LCT_Read(_LCT_RegistryDir() . "index.json"), _LCT_Read(Dir . "index.json"))
		AssertEqual('"e1"', _LCT_Read(Dir . "index.etag"))
		AssertFalse(Log[1]["headers"].Has("If-None-Match"), "nothing cached yet: no condition")

		Served := Map(LayoutRegistry_RawUrl("index.json"), Map("status", 304, "body", "", "etag", '"e1"'))
		LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome), _LCT_Transport(Served, Log), 0, false)
		AssertEqual('"e1"', Log[2]["headers"]["If-None-Match"], "the cached ETag makes the request conditional")
		AssertEqual("cache", Outcomes[2]["source"])
		AssertEqual(0, Outcomes[2]["error"], "an unchanged index is no error")

		LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome), _LCT_Transport(Map(), Log, true), 0, false)
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

Test("layout extensions: installed content is published without enable preferences (layout-extension)",
	_LCT_ExtensionPublishCase)

Test("layout extensions: quoted pack preferences survive the real config writer and loader (layout-extension-config)",
	_LCT_ExtensionConfigCase)

_LCT_ExtensionConfigCase() {
	Dir := _LCT_TempDir()
	try {
		Path := Dir . "config.toml"
		Group := "ext:ergopti:rolls"
		Section := 'hotstrings.modules."' . Group . '"'
		AssertTrue(TOML_BatchWrite(Path, [
			{ Section: "hotstrings.groups", Key: Group, Value: TOML_Bool(true) },
			{ Section: Section, Key: "comma", Value: TOML_Bool(true) }
		]))
		Target := Map("hotstrings", Map("groups", Map(Group, false), "modules", Map(Group, Map("comma", false))))
		_CMJFixtureReadonly(Path)
		AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected), "both desired leaves must survive reload")
		AssertEqual(0, Rejected)
		AssertTrue(Target["hotstrings"]["groups"][Group])
		AssertTrue(Target["hotstrings"]["modules"][Group]["comma"])
	} finally DirDelete(Dir, true)
}

Test("layout extensions: quoted dots stay within one config segment (layout-extension-config)",
	_LCT_ExtensionQuotedSegmentCase)

_LCT_ExtensionQuotedSegmentCase() {
	Dir := _LCT_TempDir()
	try {
		Path := Dir . "config.toml"
		Header := '[ "hotstrings" . ' . Chr(39) . "modules" . Chr(39) . ' . "pack.with.dot" ]'
		_LCT_WriteRaw(Path, Header . "`ncomma = true`n")
		Target := Map("hotstrings", Map("modules", Map("pack.with.dot", Map("comma", false))))
		_CMJFixtureReadonly(Path)
		AssertEqual(1, ApplyConfigToml(Target, Path, &Rejected))
		AssertEqual(0, Rejected)
		AssertTrue(Target["hotstrings"]["modules"]["pack.with.dot"]["comma"])
		_LCT_WriteRaw(Path, '["hotstrings.personal".foreign]' . "`nenabled = true`n")
		Target := Map("hotstrings", Map("personal", Map()))
		AssertEqual(0, ApplyConfigToml(Target, Path, &Rejected))
		AssertEqual("section", TomlConfigUnknownKind(Target, '"hotstrings.personal".foreign', "enabled"),
			"one quoted key cannot impersonate the two dynamic namespace segments")
		AssertFalse(Target.Has("hotstrings.personal"))
	} finally DirDelete(Dir, true)
}

Test("layout extensions: user pack overlay owns discovered files (layout-extension-runtime)",
	_LCT_ExtensionOverlayCase)

_LCT_ExtensionOverlayCase() {
	Dir := _LCT_TempDir()
	try {
		for Root in ["bundled", "installed", "user"] {
			PackDir := Dir . Root . "\ergopti\"
			DirCreate(PackDir . "hotstrings")
			_LCT_WriteRaw(PackDir . "manifest.toml", '[extension]' . "`n" . 'name = "' . Root . '"' . "`n")
			_LCT_WriteRaw(PackDir . "hotstrings\rolls.toml", '[[comma]]' . "`n" . '"aa" = { output = "b" }' . "`n")
		}
		Packs := HotstringExtensions_Scan([Dir . "bundled", Dir . "installed", Dir . "user"])
		AssertEqual(1, Packs.Length)
		AssertEqual("user", Packs[1].name)
		AssertEqual("ext:ergopti:rolls", Packs[1].toml_files[1].category)
		AssertEqual(Dir . "user\ergopti\hotstrings\rolls.toml", Packs[1].toml_files[1].path)
		AssertEqual("comma", Packs[1].toml_files[1].sections[1]["name"])
		AssertEqual(0, HotstringExtensions_Scan([Dir . "missing"]).Length)
		_LCT_WriteRaw(Dir . "not-a-directory", "content")
		AssertThrows(() => HotstringExtensions_Scan([Dir . "not-a-directory"]),
			"invalid roots cannot be published as an empty pack catalogue")
	} finally DirDelete(Dir, true)
}

Test("layout extensions: desired choices survive master gating (layout-extension-runtime)",
	_LCT_ExtensionDesiredCase)

Test("layout extensions: bound fragments preserve historical section routing (layout-extension-binding)",
	_LCT_ExtensionBindingCase)

_LCT_ExtensionBindingCase() {
	Binding := Map("category", "magickey", "feature_section", "hotstrings.magic_key",
		"source", "common", "sections", ["repeat_corrections"])
	File := { category: "ext:ergopti:magicrepeat", path: "geometry.toml", binding: Binding }
	Packs := [{ id: "ergopti", toml_files: [File] }]
	AssertEqual("geometry.toml", HotstringExtensions_Source(Packs, "magickey", "repeat_corrections"))
	AssertEqual("", HotstringExtensions_Source(Packs, "magickey", "text_expansion_symbols"))
	AssertEqual("", HotstringExtensions_Source(Packs, "magickey"), "general metadata remains owned by the base file")
	AssertEqual("geometry.toml", HotstringExtensions_Source(Packs, File.category))
	Packs.Push({ id: "conflicting", toml_files: [File] })
	AssertThrows(() => HotstringExtensions_Source(Packs, "magickey", "repeat_corrections"),
		"two owners cannot silently replace a historical section")
}

Test("layout extensions: the shared binding vectors decide the same sources on Windows (layout-extension-binding)",
	_LCT_ExtensionBindingVectorsCase)

; Replays _shared/tests/corpus/layouts/extension_binding_vectors.json through the
; real scanner on real files, the vectors the macOS and Linux suites replay.
_LCT_ExtensionBindingVectorsCase() {
	Doc := JsonParse(_LCT_Read(_SharedDir . "\tests\corpus\layouts\extension_binding_vectors.json"))
	Valid := 0, Invalid := 0
	for Scenario in Doc["cases"] {
		Dir := _LCT_TempDir()
		try {
			Root := Dir . "ext"
			for Pack in Scenario["packs"] {
				PackDir := Root . "\" . Pack["id"] . "\"
				DirCreate(PackDir . "hotstrings")
				_LCT_WriteRaw(PackDir . "manifest.toml", Pack["manifest"])
				for Stem in Pack["files"]
					_LCT_WriteRaw(PackDir . "hotstrings\" . Stem . ".toml", '[[section]]' . "`n" . '"aa" = { output = "b" }' . "`n")
			}
			if !Scenario["valid"] {
				Invalid += 1
				AssertThrows(() => HotstringExtensions_Scan([Root]), Scenario["name"])
				continue
			}
			Valid += 1
			Packs := HotstringExtensions_Scan([Root])
			Bound := Map(), Unbound := []
			for Pack in Packs {
				for File in Pack.bound_files
					Bound[Pack.id . "/" . File.stem] := File.binding
				for File in Pack.toml_files {
					AssertFalse(File.HasOwnProp("binding"), "an ext: pack carries no binding: " . Scenario["name"])
					Unbound.Push(Pack.id . "/" . File.stem)
				}
			}
			AssertEqual(Scenario["bindings"].Count, Bound.Count, Scenario["name"])
			for Key, Expected in Scenario["bindings"] {
				AssertTrue(Bound.Has(Key), Scenario["name"] . ": " . Key)
				for Field in ["category", "feature_section", "source"]
					AssertEqual(Expected[Field], Bound[Key][Field], Scenario["name"] . ": " . Key . "." . Field)
				AssertEqual(Expected.Has("sections"), Bound[Key].Has("sections"), Scenario["name"] . ": " . Key)
				if Expected.Has("sections") {
					AssertEqual(Expected["sections"].Length, Bound[Key]["sections"].Length)
					for Index, Name in Expected["sections"]
						AssertEqual(Name, Bound[Key]["sections"][Index])
				}
			}
			AssertEqual(Scenario["unbound"].Length, Unbound.Length, Scenario["name"])
			for Key in Scenario["unbound"] {
				Listed := false
				for Found in Unbound
					Listed := Listed || Found == Key
				AssertTrue(Listed, Scenario["name"] . ": " . Key)
			}
			for Query in Scenario["queries"] {
				Label := Scenario["name"] . ": " . Query["category"] . "." . Query["section"]
				if Query["source"] == "error" {
					AssertThrows(HotstringExtensions_Source.Bind(Packs, Query["category"], Query["section"]), Label)
					continue
				}
				Expected := ""
				if Query["source"] != "" {
					Parts := StrSplit(Query["source"], "/")
					Expected := Root . "\" . Parts[1] . "\hotstrings\" . Parts[2] . ".toml"
				}
				AssertEqual(Expected, HotstringExtensions_Source(Packs, Query["category"], Query["section"]), Label)
			}
		} finally DirDelete(Dir, true)
	}
	AssertTrue(Valid >= 3 && Invalid >= 5, "the shared vectors lost their coverage")
}

Test("layout extensions: the shared magic-key vectors read the same declaration on Windows (layout-magic-key)",
	_LCT_ExtensionMagicKeyVectorsCase)

; Replays _shared/tests/corpus/layouts/extension_magic_key_vectors.json through
; the real scanner on a real manifest, as the macOS and Linux suites do.
_LCT_ExtensionMagicKeyVectorsCase() {
	Doc := JsonParse(_LCT_Read(_SharedDir . "\tests\corpus\layouts\extension_magic_key_vectors.json"))
	Declared := 0, Refused := 0
	for Scenario in Doc["cases"] {
		Dir := _LCT_TempDir()
		try {
			Root := Dir . "ext"
			DirCreate(Root . "\geometry\hotstrings")
			_LCT_WriteRaw(Root . "\geometry\manifest.toml", Scenario["manifest"])
			if !Scenario["valid"] {
				Refused += 1
				AssertThrows(() => HotstringExtensions_Scan([Root]), Scenario["name"])
				continue
			}
			Packs := HotstringExtensions_Scan([Root])
			AssertEqual(1, Packs.Length, Scenario["name"])
			AssertEqual(Scenario["magic_key"], Packs[1].magic_key, Scenario["name"])
			if Scenario["magic_key"] != ""
				Declared += 1
		} finally DirDelete(Dir, true)
	}
	AssertTrue(Declared >= 2 && Refused >= 4, "the shared vectors lost their coverage")
}

_LCT_ExtensionDesiredCase() {
	Category := "ext:ergopti:rolls"
	Packs := [{ id: "ergopti", name: "Ergopti", toml_files: [
		{ category: Category, path: "private-rolls.toml", sections: [Map("name", "comma"), Map("name", "other")] }
	]}]
	Target := Map("hotstrings", Map())
	HotstringExtensions_Seed(Target, Packs, (*) => false)
	AssertEqual(0, HotstringExtensions_RegistrationPlan(Target, Packs, true).Length,
		"discovery cannot activate absent group or section preferences")
	Target["hotstrings"]["groups"][Category] := true
	Target["hotstrings"]["modules"][Category]["comma"] := true
	HotstringExtensions_Seed(Target, Packs, (*) => false)
	AssertTrue(Target["hotstrings"]["groups"][Category], "refresh preserves the explicit group choice")
	AssertTrue(Target["hotstrings"]["modules"][Category]["comma"], "refresh preserves explicit section choice")
	AssertEqual(0, HotstringExtensions_RegistrationPlan(Target, Packs, false).Length)
	Plan := HotstringExtensions_RegistrationPlan(Target, Packs, true)
	AssertEqual(1, Plan.Length)
	AssertEqual(Category, Plan[1].category)
	AssertEqual("comma", Plan[1].section)
	AssertEqual("private-rolls.toml", Plan[1].path)
	AssertFalse(Target["hotstrings"]["modules"][Category]["other"])
	Target["hotstrings"]["groups"][Category] := "false"
	AssertThrows(() => HotstringExtensions_RegistrationPlan(Target, Packs, true),
		"a quoted string must never become an effective activation")
}

_LCT_ExtensionPublishCase() {
	Dir := _LCT_TempDir()
	try {
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())
		AssertTrue(Result[1])
		Entry := LayoutCatalogue_ReadInstalled(Dir)["ergol"]
		AssertTrue(Entry.Has("extension"), "the published record owns the complete extension generation")
		Extension := Entry["extension"]
		Root := Dir . "extensions\ergol\" . Extension["sha256"] . "\" . Extension["id"] . "\"
		for File in Extension["files"] {
			Path := Root . StrReplace(File["path"], "/", "\")
			AssertTrue(FileExist(Path), "every advertised extension file is available before publication")
			AssertEqual(File["sha256"], CryptoSha256(_LCT_Read(Path)))
		}
		AssertFalse(FileExist(Dir . "config.toml"), "installing content never enables it")
	} finally DirDelete(Dir, true)
}

Test("layout extensions: a corrupt manifest leaves the installed record unchanged (layout-extension)",
	_LCT_ExtensionRefusalCase)

_LCT_ExtensionRefusalCase() {
	Dir := _LCT_TempDir()
	Shipped := _LCT_TempDir()
	try {
		AssertTrue(_LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())[1])
		Before := _LCT_Read(Dir . "installed.json")
		DirCopy(_LCT_RegistryDir(), Shipped, true)
		_LCT_WriteRaw(Shipped . "ergol\manifest.toml", "corrupt")
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), Shipped)
		AssertFalse(Result[1], "a layout file alone cannot publish an incomplete extension")
		AssertEqual(Before, _LCT_Read(Dir . "installed.json"))
	} finally {
		DirDelete(Dir, true)
		DirDelete(Shipped, true)
	}
}

_LCT_InstallCase() {
	Dir := _LCT_TempDir()
	try {
		Log := []
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(_LCT_Served(_LCT_LayoutText("ergol")), Log))
		AssertTrue(Result[1], "the installation must succeed: " . (Result[2] is String ? Result[3] : ""))
		AssertEqual("network", Result[2]["source"])
		AssertEqual(1 + LayoutCatalogue_Entry(_LCT_Index(), "ergol")["extension"]["files"].Length, Log.Length,
			"the index and complete extension; the verified layout is reused")
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

Test("layout catalogue: a refused update keeps the installed layout the emulation reads (layout-catalogue)",
	_LCT_RefusedUpdateCase)

_LCT_RefusedUpdateCase() {
	Dir := _LCT_TempDir()
	try {
		AssertTrue(_LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())[1])
		Record := _LCT_Read(Dir . "installed.json")
		Tampered := _LCT_Tamper(_LCT_LayoutText("ergol"), 'output="q"', 'output="z"')
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(_LCT_Served(Tampered), []))
		AssertFalse(Result[1], "a download that does not match its index is refused")
		AssertEqual(LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, Result[2])
		AssertEqual(_LCT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"],
			"the verified copy the emulation boots from survives the refused update")
		AssertEqual(Record, _LCT_Read(Dir . "installed.json"), "and so does its record")
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
		for Text in ["{ damaged", '{"schema_version": 2, "layouts": {}}', '{"schema_version": 1}'] {
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

_LCT_InstalledChannelUrls() {
	global BUNDLE_CHANNEL
	HadChannel := IsSet(BUNDLE_CHANNEL)
	Original := HadChannel ? BUNDLE_CHANNEL : ""
	try {
		for Channel in UpdateChannels_Ids() {
			BUNDLE_CHANNEL := Channel
			AssertTrue(InStr(LayoutRegistry_RawUrl("index.json"), "/" . Channel . "/") > 0,
				"catalogue URLs must use the installed channel")
		}
		BUNDLE_CHANNEL := "__UNRELEASED__"
		AssertTrue(InStr(LayoutRegistry_RawUrl("index.json"), "/" . UpdateChannels_UnreleasedBuildChannel() . "/") > 0)
	} finally {
		BUNDLE_CHANNEL := HadChannel ? Original : unset
	}
}
Test("layout catalogue follows packaged and local build channels (layout-registry-channel)", _LCT_InstalledChannelUrls)

_LCT_OutdatedCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "/tests/corpus/layouts/installed_record_outdated.json", "UTF-8"))
}

_LCT_OutdatedSource(Corpus, IncludeValid := true) {
	Rows := IncludeValid ? Corpus["valid_member"] : ""
	for Vector in Corpus["outdated"]
		Rows .= (Rows != "" ? "," : "") . Vector["member"]
	return '{"schema_version":1,' . Corpus["top_member"] . ',"layouts":{' . Rows . "}}"
}

_LCT_OutdatedRawMembers(Corpus, Source) {
	AssertTrue(InStr(Source, Corpus["top_member"], true) > 0, "future header retains its exact JSON identities")
	for Vector in Corpus["outdated"]
		AssertTrue(InStr(Source, Vector["member"], true) > 0,
			"obsolete source member remains exact: " . Vector["id"])
}

_LCT_EqualSourceBytes(Expected, Actual) {
	AssertEqual(Expected.Size, Actual.Size, "source byte count remains exact")
	loop Expected.Size
		AssertEqual(NumGet(Expected, A_Index - 1, "UChar"), NumGet(Actual, A_Index - 1, "UChar"),
			"source byte " . A_Index)
}

_LCT_OutdatedRecordReadsAndWrites() {
	global _LOGGER_REPEAT_ENABLED
	Dir := _LCT_TempDir(), Corpus := _LCT_OutdatedCorpus()
	Captured := [], PreviousRepeat := _LOGGER_REPEAT_ENABLED
	_LOGGER_REPEAT_ENABLED := false
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := Dir . "installed.json"
		_LCT_WriteRaw(Path, _LCT_OutdatedSource(Corpus))
		Before := FileRead(Path, "RAW")
		loop 3 {
			Installed := LayoutCatalogue_ReadInstalled(Dir)
			AssertEqual(1, Installed.Count, "outdated entries cannot hide the usable neighbor or add phantom layouts")
			AssertTrue(Installed.Has("sample"))
			AssertEqual("1", Installed["sample"]["version"])
			for Vector in Corpus["outdated"]
				AssertFalse(Installed.Has(Vector["id"]), "obsolete entry stays outside runtime membership")
			LoggerWarn("LayoutCatalogue", "Interleaved catalogue-read fixture warning {1}.", A_Index)
		}
		_LCT_EqualSourceBytes(Before, FileRead(Path, "RAW"))
		Counts := Map(), Errors := 0
		for Vector in Corpus["outdated"]
			Counts[Vector["id"]] := 0
		for Line in Captured {
			if InStr(Line, "[ERROR]", true)
				Errors += 1
			for Vector in Corpus["outdated"] {
				EntryPath := "layouts[" . JsonStringLiteral(Vector["id"]) . "]"
				if InStr(Line, "[WARNING]", true) && InStr(Line, EntryPath, true) {
					Counts[Vector["id"]] += 1
					AssertTrue(InStr(Line, Path, true) > 0, "the warning names its actual file")
					AssertTrue(InStr(Line, Vector["detail"], true) > 0, "independent reason is reported")
				}
			}
		}
		AssertEqual(0, Errors, "obsolete records are warnings rather than whole-file errors")
		for Id, Count in Counts
			AssertEqual(1, Count, "interleaved actual reads warn once: " . Id)
		Copied := Installed.Clone()
		AssertTrue(Copied.HasOwnProp("_LayoutCatalogueRecordSource"), "native Map.Clone retains non-enumerable source ownership")
		LayoutCatalogue_WriteInstalled(Dir, Copied)
		Written := _LCT_Read(Path)
		_LCT_OutdatedRawMembers(Corpus, Written)
		AssertTrue(InStr(Written, Corpus["valid_member"], true) > 0, "an unchanged valid row keeps future source values")
		Installed := LayoutCatalogue_ReadInstalled(Dir)
		Installed["sample"] := Map("id", "sample", "sha256", "x", "version", "2", "size", 1)
		LayoutCatalogue_WriteInstalled(Dir, Installed)
		Written := _LCT_Read(Path)
		_LCT_OutdatedRawMembers(Corpus, Written)
		AssertTrue(InStr(Written, Corpus["valid_future_member"], true) > 0, "updating known fields cannot erase future values")
		AssertEqual("2", LayoutCatalogue_ReadInstalled(Dir)["sample"]["version"])
	} finally {
		_LOGGER_REPEAT_ENABLED := PreviousRepeat
		LoggerClearTestSink()
		DirDelete(Dir, true)
	}
}
Test("layout catalogue: obsolete record rows warn once and preserve actual source neighbors (config-outdated-installed)",
	_LCT_OutdatedRecordReadsAndWrites)

_LCT_OutdatedRecordInstallAndUninstall() {
	Dir := _LCT_TempDir(), Corpus := _LCT_OutdatedCorpus()
	try {
		Path := Dir . "installed.json"
		_LCT_WriteRaw(Path, _LCT_OutdatedSource(Corpus, false))
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())
		AssertTrue(Result[1], "an obsolete neighbor cannot refuse the actual verified installation")
		AssertEqual(1, LayoutCatalogue_ReadInstalled(Dir).Count)
		AssertEqual(_LCT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"], "the real local owner verifies the installed copy")
		_LCT_OutdatedRawMembers(Corpus, _LCT_Read(Path))
		Before := FileRead(Path, "RAW")
		Rejected := LayoutCatalogue_Uninstall("renamed", Dir)
		AssertFalse(Rejected["ok"], "an obsolete row cannot become an installed native target")
		AssertEqual(LAYOUT_CATALOGUE_FAILURE_NOT_INSTALLED, Rejected["code"])
		_LCT_EqualSourceBytes(Before, FileRead(Path, "RAW"))
		AssertTrue(FileExist(Dir . "ergol.keylayout"), "refusing an obsolete target leaves valid copies alone")
		AssertTrue(LayoutCatalogue_Uninstall("ergol", Dir)["ok"], "actual uninstall still commits")
		AssertFalse(FileExist(Dir . "ergol.keylayout"))
		AssertEqual(0, LayoutCatalogue_ReadInstalled(Dir).Count, "outdated metadata does not enumerate as a layout")
		_LCT_OutdatedRawMembers(Corpus, _LCT_Read(Path))
		AssertEqual(0, LayoutCatalogue_Busy())
	} finally DirDelete(Dir, true)
}
Test("layout catalogue: actual install and uninstall keep obsolete rows and future header data (config-outdated-installed)",
	_LCT_OutdatedRecordInstallAndUninstall)

_LCT_OutdatedSourceReceiptRefusal() {
	Dir := _LCT_TempDir(), OtherDir := _LCT_TempDir(), Corpus := _LCT_OutdatedCorpus()
	try {
		Path := Dir . "installed.json"
		_LCT_WriteRaw(Path, _LCT_OutdatedSource(Corpus))
		Installed := LayoutCatalogue_ReadInstalled(Dir)
		AssertThrows(() => LayoutCatalogue_WriteInstalled(OtherDir, Installed), "source metadata cannot borrow another file identity")
		AssertFalse(FileExist(OtherDir . "installed.json"))
		Changed := _LCT_Read(Path) . " "
		_LCT_WriteRaw(Path, Changed)
		Before := FileRead(Path, "RAW")
		Installed["sample"]["version"] := "2"
		AssertThrows(() => LayoutCatalogue_WriteInstalled(Dir, Installed), "held source metadata cannot overwrite changed source bytes")
		_LCT_EqualSourceBytes(Before, FileRead(Path, "RAW"))
	} finally {
		DirDelete(Dir, true)
		DirDelete(OtherDir, true)
	}
}
Test("layout catalogue: raw member metadata cannot cross file identity or source drift (config-outdated-installed)",
	_LCT_OutdatedSourceReceiptRefusal)


_LCT_CaseDistinctFutureMembers() {
	Dir := _LCT_TempDir()
	try {
		Path := Dir . "installed.json"
		Source := '{"schema_version":1,"Layouts":null,"LAYOUTS":false,"Schema_Version":1.25e+2,"SCHEMA_VERSION":[],"layouts":{"sample":{"id":"sample","sha256":"x","version":"1","size":1,"Case":1,"case":2},"ergol":false}}'
		Future := ['"Layouts":null', '"LAYOUTS":false', '"Schema_Version":1.25e+2', '"SCHEMA_VERSION":[]']
		_LCT_WriteRaw(Path, Source)
		Before := FileRead(Path, "RAW")
		Installed := LayoutCatalogue_ReadInstalled(Dir)
		AssertEqual(1, Installed.Count, "cased future headers do not enumerate as layouts")
		AssertEqual(1, Installed["sample"]["Case"]), AssertEqual(2, Installed["sample"]["case"])
		AssertEqual("1", Installed._LayoutCatalogueRecordSource.original["sample"]["version"])
		_LCT_EqualSourceBytes(Before, FileRead(Path, "RAW"))
		LayoutCatalogue_WriteInstalled(Dir, Installed)
		for Member in Future
			AssertTrue(InStr(_LCT_Read(Path), Member, true) > 0, "ordinary save preserves distinct JSON header: " . Member)
		Installed := LayoutCatalogue_ReadInstalled(Dir)
		Installed["sample"]["version"] := "2"
		AssertEqual("1", Installed._LayoutCatalogueRecordSource.original["sample"]["version"],
			"the original snapshot is detached from an in-place entry mutation")
		LayoutCatalogue_WriteInstalled(Dir, Installed)
		AssertEqual("2", LayoutCatalogue_ReadInstalled(Dir)["sample"]["version"])
		for Member in Future
			AssertTrue(InStr(_LCT_Read(Path), Member, true) > 0, "in-place update preserves distinct JSON header: " . Member)
		AssertTrue(InStr(_LCT_Read(Path), '"ergol":false', true) > 0, "unrelated save preserves the obsolete same-id row")
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())
		AssertTrue(Result[1], "explicit verified install replaces the obsolete same-id row")
		AssertEqual(2, LayoutCatalogue_ReadInstalled(Dir).Count)
		AssertEqual(_LCT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"])
		AssertFalse(InStr(_LCT_Read(Path), '"ergol":false', true) > 0, "only explicit installation retires that obsolete record")
		for Member in Future
			AssertTrue(InStr(_LCT_Read(Path), Member, true) > 0, "actual installation preserves distinct JSON header: " . Member)
		AssertTrue(LayoutCatalogue_Uninstall("ergol", Dir)["ok"])
		AssertEqual(1, LayoutCatalogue_ReadInstalled(Dir).Count)
		for Member in Future
			AssertTrue(InStr(_LCT_Read(Path), Member, true) > 0, "actual uninstall preserves distinct JSON header: " . Member)
		Written := _LCT_Read(Path)
		AssertTrue(InStr(Written, '"Case":1', true) > 0), AssertTrue(InStr(Written, '"case":2', true) > 0)
		AssertEqual(0, LayoutCatalogue_Busy())
	} finally DirDelete(Dir, true)
}
Test("layout catalogue: case-distinct future headers survive real save install and uninstall (config-outdated-installed)",
	_LCT_CaseDistinctFutureMembers)


_LCT_RecordValueStringIdentity() {
	AssertFalse(_LayoutCatalogueSameValue(JsonParse('"Case"'), JsonParse('"case"')),
		"JSON string case changes are explicit record changes")
	AssertFalse(_LayoutCatalogueSameValue(JsonParse('"01"'), JsonParse('"1"')),
		"distinct numeric-looking JSON strings are distinct record values")
	AssertFalse(_LayoutCatalogueSameValue(JsonParse('"1"'), JsonParse('1')),
		"JSON string and number identities stay distinct")
	AssertTrue(_LayoutCatalogueSameValue(JsonParse('"before\u0000one"'), JsonParse('"before\u0000one"')),
		"an unchanged NUL-containing JSON value preserves its original token")
	AssertFalse(_LayoutCatalogueSameValue(JsonParse('"before\u0000one"'), JsonParse('"before\u0000two"')),
		"the stored UTF-16 suffix after NUL remains part of JSON string identity")
}
Test("layout catalogue: raw preservation compares exact JSON string identities (config-outdated-installed)",
	_LCT_RecordValueStringIdentity)
