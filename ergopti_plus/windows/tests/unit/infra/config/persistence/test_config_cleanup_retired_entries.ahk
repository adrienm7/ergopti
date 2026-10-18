; tests/unit/infra/config/persistence/test_config_cleanup_retired_entries.ahk

; ==============================================================================
; MODULE: Config Cleanup of Retired Entries
; DESCRIPTION:
; Retired prefixes and empty retired tables are removed through the real
; preview, backup and semantic deletion; unsupported projections refuse,
; warnings stay truthful and differently cased segments never enter retired
; admission.
; ==============================================================================

#Requires AutoHotkey v2.0





; The physical fixture is exclusively owned, including its verified backups.
_CUK_RetiredNewDir() {
	static Sequence := 0
	Sequence += 1
	Folder := A_Temp . "\ergopti_retired_cleanup_" . A_ScriptHwnd
		. "_" . A_TickCount . "_" . Sequence
	AssertTrue(DllCall("CreateDirectoryW", "Str", Folder, "Ptr", 0, "Int"),
		"the fixture must exclusively own its native directory")
	return Folder
}

_CUK_RetiredRows(Scan) {
	AssertEqual("ok", Scan["status"])
	Rows := []
	for Entry in Scan["keys"] {
		if _ConfigUnusedKeysRetiredSection(Entry["section"])
			Rows.Push(Entry)
	}
	return Rows
}

_CUK_RetiredPrefixActualCleanup() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Retired := "# Retired namespace preview.`n[ahk]`n`n"
		. "[ahk.layout]`nflag = true`n`n"
		. "[ahk.layout.deep]`n" . 'label = "retain until cleanup"' . "`n`n"
		. "[ahk.empty]`n`n"
	Kept := _CUK_CurrentMetadata() . "`n"
		. "[updater]`n" . 'channel = "stable"' . "`n`n"
		. "[hotstrings.personal.mine]`nenabled = true`n`n"
		. '["ahk.foo"]' . "`n" . 'keep = "literal"' . "`n`n"
		. "[AHK.layout]`n" . 'keep = "case"' . "`n`n"
		. "[future_extension]`nkeep = 42 # preserve exact comment`n"
	Source := Retired . Kept
	Expected := Chr(0xFEFF) . "# Retired namespace preview.`n`n`n`n`n" . Kept
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		_CUK_AssertIds("ahk.=section|ahk.layout.flag=section|ahk.layout.deep.label=section|ahk.empty.=section",
			Rows)
		RootRow := _CUK_RequireId(Rows, "ahk.=section")
		EmptyRow := _CUK_RequireId(Rows, "ahk.empty.=section")
		AssertTrue(RootRow["section_only"] is Integer)
		AssertEqual(1, RootRow["section_only"])
		AssertTrue(EmptyRow["section_only"] is Integer)
		AssertEqual(1, EmptyRow["section_only"])
		AssertEqual(Source, FSReadUtf8Exact(Path), "scanning never accepts cleanup")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000201", 0, 0, Source)
		AssertEqual("removed", Result["status"])
		AssertEqual(4, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]),
			"the actual native backup contains the exact preview generation")
		AssertEqual(Expected, FSReadUtf8Exact(Path),
			"actual semantic cleanup drops only explicitly offered retired identities")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Document.Has("ahk"))
		AssertEqual("literal", Document["ahk.foo"]["keep"])
		AssertEqual("case", Document["AHK"]["layout"]["keep"])
		AssertEqual("stable", Document["updater"]["channel"])
		AssertEqual(ConfigMigrateCurrentVersion(), Document["_meta"]["schema_version"])
		AssertTrue(Document["hotstrings"]["personal"]["mine"]["enabled"] is TOML_Bool)
		AssertEqual(true, Document["hotstrings"]["personal"]["mine"]["enabled"].Value)
		AssertEqual(42, Document["future_extension"]["keep"])
		AssertEqual(0, _CUK_RetiredRows(ConfigUnusedKeysFind(Path)).Length)
	} finally DirDelete(Folder, true)
}
Test("config cleanup: actual retired prefix removal preserves reserved literal and case twins "
	. "(config-retired-explicit-cleanup)", _CUK_RetiredPrefixActualCleanup)

_CUK_RetiredEmptyTablesActualCleanup() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk]`n`n[ahk.empty]`n`n[updater]`n" . 'channel = "stable"' . "`n" . _CUK_CurrentMetadata()
	Expected := Chr(0xFEFF) . "`n`n[updater]`n" . 'channel = "stable"' . "`n" . _CUK_CurrentMetadata()
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual("ahk.=section|ahk.empty.=section", _CUK_Join(_CUK_Ids(Rows)))
		AssertEqual("{}", Rows[1]["value"])
		AssertTrue(_ConfigUnusedKeysSectionOnly(Rows[1]))
		AssertTrue(_ConfigUnusedKeysSectionOnly(Rows[2]))
		Session := ConfigCleanupSession(Path)
		try {
			AssertEqual("ready", Session.Handle("ready")["status"])
			Page := JsonParse(Session.Json())
			AssertEqual(2, Page["keys"].Length)
			AssertEqual("", Page["keys"][1]["key"])
			AssertEqual("{}", Page["keys"][1]["value"])
			AssertFalse(Page["keys"][1].Has("section_only"),
				"the private whole-section authorization never enters the page contract")
			Result := Session.Handle(Map("action", "clean", "session", Session.Token))
			AssertEqual("removed", Result["status"])
			AssertEqual(2, Result["removed"])
			AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
			AssertEqual(Expected, FSReadUtf8Exact(Path))
		} finally Session.Close()
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length)
	} finally DirDelete(Folder, true)
}
Test("config cleanup: empty retired tables use real preview backup and semantic deletion "
	. "(config-retired-explicit-cleanup)", _CUK_RetiredEmptyTablesActualCleanup)

_CUK_RetiredEmptyTableCannotOwnLateChild(ChildSource) {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk]`n`n[updater]`n" . 'channel = "stable"' . "`n" . _CUK_CurrentMetadata()
	Concurrent := Source . ChildSource
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		AssertTrue(_ConfigUnusedKeysSectionOnly(Rows[1]))
		AssertEqual(1, FSWriteDurable(Path, Concurrent))
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000202")
		AssertEqual("changed", Result["status"],
			"a direct old empty-table scan cannot own an unlisted semantic child")
		AssertEqual(0, Result["removed"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "refusal precedes backup and publication")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000203", 0, 0, Source)
		AssertEqual("changed", Result["status"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "stale preview bytes cannot authorize any transaction")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: retired empty-table preview cannot own late descendants or stale bytes "
	. "(config-retired-explicit-cleanup)",
	_CUK_RetiredEmptyTableCannotOwnLateChild.Bind("`n[ahk.late]`nflag = true`n"))
Test("config cleanup: retired empty-table preview cannot own an unlisted empty child header "
	. "(config-retired-explicit-cleanup)",
	_CUK_RetiredEmptyTableCannotOwnLateChild.Bind("`n[ahk.late]`n"))

_CUK_RetiredBackupRaceUsesExactSource() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk.layout]`nflag = true`n`n[future_extension]`nkeep = 42`n" . _CUK_CurrentMetadata()
	Concurrent := "[ahk.layout]`nflag = true`n`n[future_extension]`nkeep = 43`n" . _CUK_CurrentMetadata()
	Seen := Map("backup_calls", 0, "lease_blocked", false)
	Backup(Target, Content) {
		Seen["backup_calls"] += 1
		Owner := _ConfigWriteLeaseTryAcquire(Path, "foreign-backup-probe")
		Seen["lease_blocked"] := !(Owner is Object)
		if Owner is Object
			_ConfigWriteLeaseRelease(Owner)
		Written := FSWriteCreateDurable(Target, Content)
		if !(Written is Integer) || Written != 1
			return Written
		Changed := FSWriteDurable(Path, Concurrent)
		if !(Changed is Integer) || Changed != 1
			throw Error("the actual native fixture could not publish its foreign source generation")
		return Written
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000204", Backup, 0, Source)
		AssertEqual("write_failed", Result["status"],
			"the actual default writer must refuse a source changed during verified backup")
		AssertEqual(0, Result["removed"])
		AssertEqual(1, Seen["backup_calls"])
		AssertTrue(Seen["lease_blocked"], "one source lease spans native backup and publication refusal")
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(Concurrent, FSReadUtf8Exact(Path),
			"a foreign generation remains byte-exact, including its retired entries")
		Owner := _ConfigWriteLeaseTryAcquire(Path, "post-cleanup-probe")
		try AssertTrue(Owner is Object, "refusal must release its original source lease")
		finally {
			if Owner is Object
				_ConfigWriteLeaseRelease(Owner)
		}
	} finally DirDelete(Folder, true)
}
Test("config cleanup: actual default writer binds the exact verified backup generation "
	. "(config-retired-backup-source-race)", _CUK_RetiredBackupRaceUsesExactSource)

_CUK_RetiredUnsupportedProjection(Source, Mode) {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source .= _CUK_CurrentMetadata()
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		; These requests have no privately captured whole-root capability. Actual
		; typed producers are qualified separately; metadata cannot substitute.
		switch Mode {
			case "unproven": Rows := [Map("section", "ahk", "key", "layout.flag", "kind", "section", "value", "true")]
			case "forged": Rows := [Map("section", "ahk", "key", "", "kind", "section", "value", "{}", "retired_root_receipt", Map())]
			case "partial": Rows := [Map("section", "ahk.items", "key", "flag", "kind", "section", "value", "true")]
			default: throw ValueError("Unknown unsupported root fixture")
		}
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000300", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"],
			"an unproved flat retired projection cannot manufacture whole-section authorization")
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "refusal precedes backup and publication")
		AssertFalse(ConfigUnusedKeysOffer(Path, (*) => Map("status", "unsupported", "keys", []), (*) => false))
		AssertEqual(Source, FSReadUtf8Exact(Path))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: retired dotted assignments refuse unproved flat ownership (config-retired-unsupported)",
	_CUK_RetiredUnsupportedProjection.Bind("[ahk]`nlayout.flag = true`n", "unproven"))
Test("config cleanup: retired inline root refuses forged whole-root authority (config-retired-unsupported)",
	_CUK_RetiredUnsupportedProjection.Bind("ahk = {layout = {flag = true}}`n", "forged"))
Test("config cleanup: retired table-array generations refuse partial flat ownership (config-retired-unsupported)",
	_CUK_RetiredUnsupportedProjection.Bind("[[ahk.items]]`nflag = true`n", "partial"))

_CUK_RetiredWarningAndRuntimeNeutrality() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk.layout]`nergopti_base = true`n"
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		AssertEqual(0, ApplyConfigToml(Target, Path, &Rejected))
		AssertEqual(0, Rejected)
		AssertEqual(false, Target["layout"]["ergopti_base"])
		Errors := 0, Named := 0
		for Line in Lines {
			if InStr(Line, "[ERROR]")
				Errors += 1
			if InStr(Line, "[WARNING]") && InStr(Line, "obsolete [ahk.*]")
					&& InStr(Line, "remain until explicit cleanup")
				Named += 1
			AssertFalse(InStr(Line, "next canonical save removes") > 0)
		}
		AssertEqual(0, Errors)
		AssertEqual(1, Named)
		AssertEqual(Source, FSReadUtf8Exact(Path), "the warning never performs cleanup")
		AssertEqual(1, _CUK_RetiredRows(ConfigUnusedKeysFind(Path)).Length)
	} finally {
		LoggerClearTestSink()
		DirDelete(Folder, true)
	}
}
Test("config cleanup: retired entries warn truthfully remain runtime neutral and await explicit cleanup "
	. "(config-retired-explicit-cleanup)", _CUK_RetiredWarningAndRuntimeNeutrality)


_CUK_RetiredCaseTwinScanIsIndependent() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[AHK.layout]`nflag = true`n"
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"],
			"a differently cased source segment cannot enter retired-prefix admission")
		AssertEqual(0, Scan["keys"].Length,
			"the existing skipped case twin must not be manufactured into retired cleanup ownership")
		AssertEqual(Source, FSReadUtf8Exact(Path))
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Document.Has("ahk"))
		AssertTrue(Document.Has("AHK"))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: differently cased source segment never enters retired admission "
	. "(config-retired-case-identity)", _CUK_RetiredCaseTwinScanIsIndependent)
