; tests/unit/infra/config/persistence/test_config_cleanup_retired_root.ahk

; ==============================================================================
; MODULE: Config Cleanup of Retired Root Namespaces
; DESCRIPTION:
; A privately captured retired root namespace is removed through the actual
; verified publication, and its receipt cannot be mutated, borrowed,
; replayed or raced through the backup.
; ==============================================================================

#Requires AutoHotkey v2.0





; Independent whole source images; the production renderer never creates these expectations.
_CUK_RetiredRootVector(Kind) {
	switch Kind {
		case "dotted":
			Source := "# retired dotted root`n" . 'ahk.layout.flag = true' . "`n"
				. 'ahk.layout.label = "retired"' . "`n`n"
		case "inline":
			Source := "# retired inline root`n" . 'ahk = {layout = {flag = true}, items = [{id = "a"}, {id = "b"}]}' . "`n`n"
		case "array":
			Source := "# retired array root`n[[ahk.items]]`nflag = true`n"
				. 'id = "first"' . "`n[[ahk.items]]`nflag = 0`n" . 'id = "second"' . "`n`n"
		default: throw ValueError("Unknown retired root fixture")
	}
	Root := "# exact root neighbors`n" . '"ahk.literal" = {keep = "literal", empty = []} # root comment' . "`n"
		. 'AHK = {keep = "case", flag = false}' . "`n`n"
	Tables := _CUK_CurrentMetadata() . "`n[updater]`n" . 'channel = "stable" # updater comment' . "`n`n"
		. "[hotstrings.personal.mine]`nenabled = true`ntime_activation_seconds = 0.75`n`n"
		. "[_future]`nflag = false`nzero = 0`nvalues = [1, 2]`nempty = []`n"
		. "stamp = 2026-10-05T10:20:30Z`n" . '"literal.dot" = "keep" # exact future comment' . "`n"
	return Map("source", Root . Source . Tables,
		"expected", Chr(0xFEFF) . Root . "# retired " . Kind . " root`n`n" . Tables)
}

_CUK_RetiredRootTypedNeighbors(Document) {
	AssertFalse(Document.Has("ahk"), "only the exact retired root is gone")
	AssertEqual("literal", Document["ahk.literal"]["keep"])
	AssertTrue(Document["ahk.literal"]["empty"] is Array)
	AssertEqual(0, Document["ahk.literal"]["empty"].Length)
	AssertEqual("case", Document["AHK"]["keep"])
	AssertTrue(Document["AHK"]["flag"] is TOML_Bool)
	AssertEqual(false, Document["AHK"]["flag"].Value)
	AssertEqual(ConfigMigrateCurrentVersion(), Document["_meta"]["schema_version"])
	AssertEqual("stable", Document["updater"]["channel"])
	AssertTrue(Document["hotstrings"]["personal"]["mine"]["enabled"] is TOML_Bool)
	AssertEqual(true, Document["hotstrings"]["personal"]["mine"]["enabled"].Value)
	AssertEqual(0.75, Document["hotstrings"]["personal"]["mine"]["time_activation_seconds"])
	AssertTrue(Document["_future"]["flag"] is TOML_Bool)
	AssertEqual(false, Document["_future"]["flag"].Value)
	AssertTrue(Document["_future"]["zero"] is Integer)
	AssertFalse(Document["_future"]["zero"] is TOML_Bool)
	AssertEqual(0, Document["_future"]["zero"])
	Values := Document["_future"]["values"]
	AssertTrue(Values is Array, "the unrelated future array keeps its native shape")
	AssertEqual(2, Values.Length, "both unrelated numeric elements survive cleanup")
	AssertTrue(Values[1] is Integer)
	AssertTrue(Values[2] is Integer)
	AssertEqual(1, Values[1], "the first independently supplied element is retained")
	AssertEqual(2, Values[2], "the second independently supplied element is retained")
	AssertEqual("1|2", _CUK_Join(Values), "the existing diagnostic joiner uses a pipe separator")
	AssertTrue(Document["_future"]["empty"] is Array)
	AssertEqual(0, Document["_future"]["empty"].Length)
	AssertEqual("2026-10-05T10:20:30Z", Document["_future"]["stamp"])
	AssertEqual("keep", Document["_future"]["literal.dot"])
}

_CUK_RetiredRootActualCleanup(Kind) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector(Kind), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length, "the complete retired namespace is one explicit native preview")
		if Rows.Length != 1
			return
		Entry := Rows[1]
		AssertEqual("ahk", Entry["section"])
		AssertEqual("", Entry["key"])
		AssertEqual("section", Entry["kind"])
		AssertEqual("_ConfigUnusedKeysRetiredRootReceipt", Type(Entry["retired_root_receipt"]))
		AssertFalse(_ConfigUnusedKeysSectionOnly(Entry), "a whole root is not an empty-table marker")
		AssertEqual(Source, FSReadUtf8Exact(Path), "collection never accepts cleanup")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000301", 0, 0, Source)
		AssertEqual("removed", Result["status"])
		AssertEqual(1, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(Vector["expected"], FSReadUtf8Exact(Path), "independent complete physical image")
		_CUK_RetiredRootTypedNeighbors(TOML_ParseDocument(FSReadUtf8Exact(Path)))
		AssertEqual(0, _CUK_RetiredRows(ConfigUnusedKeysFind(Path)).Length)
	} finally DirDelete(Folder, true)
}
Test("config cleanup: privately captured root dotted namespace uses actual verified publication (config-retired-root)",
	_CUK_RetiredRootActualCleanup.Bind("dotted"))
Test("config cleanup: privately captured inline namespace uses actual verified publication (config-retired-root)",
	_CUK_RetiredRootActualCleanup.Bind("inline"))
Test("config cleanup: privately captured table-array root removes all exact generations (config-retired-root)",
	_CUK_RetiredRootActualCleanup.Bind("array"))

_CUK_RetiredRootPrivatePage() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("array")
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Vector["source"]))
		_CUK_AdmitCurrentSource(Path)
		Session := ConfigCleanupSession(Path)
		try {
			Status := Session.Handle("ready")["status"]
			AssertEqual("ready", Status)
			if Status != "ready"
				return
			Page := JsonParse(Session.Json())
			AssertEqual(1, Page["keys"].Length)
			if Page["keys"].Length != 1
				return
			AssertEqual(3, Page["keys"][1].Count, "only descriptive source fields reach the page")
			AssertFalse(Page["keys"][1].Has("retired_root_receipt"))
			AssertFalse(Page["keys"][1].Has("Source"))
			AssertFalse(Session.Handle(Map("action", "clean", "session", "foreign")))
			AssertEqual(Vector["source"], FSReadUtf8Exact(Path))
			Result := Session.Handle(Map("action", "clean", "session", Session.Token,
				"keys", [Map("section", "updater", "key", "channel")]))
			AssertEqual("removed", Result["status"], "page metadata cannot choose another removal")
			AssertEqual(Vector["source"], FSReadUtf8Exact(Result["backup"]))
			AssertEqual(Vector["expected"], FSReadUtf8Exact(Path))
			AssertFalse(Session.Handle(Map("action", "clean", "session", Session.Token)))
		} finally Session.Close()
	} finally DirDelete(Folder, true)
}
Test("config cleanup: actual host keeps the complete retired source receipt private and action-only (config-retired-root)",
	_CUK_RetiredRootPrivatePage)

_CUK_RetiredRootRefusesMutation(Field, Replacement) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("inline"), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		if Field == "extra"
			Rows[1]["forged"] := Replacement
		else if Field == "case_sense" {
			Fields := Rows[1].Clone()
			Rows[1].Clear()
			Rows[1].CaseSense := Replacement
			for Name, Value in Fields
				Rows[1][Name] := Value
		}
		else if Field == "field_case" {
			Rows[1].Delete("section")
			Rows[1]["Section"] := Replacement
		} else
			Rows[1][Field] := Replacement
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000302", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "same-object metadata mutation refuses before backup")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: a same-map section mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("section", "AHK"))
Test("config cleanup: a same-map key mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("key", "layout"))
Test("config cleanup: a same-map kind mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("kind", "leaf"))
Test("config cleanup: a same-map display-value mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("value", "{}"))
Test("config cleanup: a same-map value type mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("value", 1))
Test("config cleanup: extra same-map metadata cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("extra", true))
Test("config cleanup: native map case-policy mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("case_sense", "Off"))
Test("config cleanup: renamed native metadata fields cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("field_case", "ahk"))

_CUK_RetiredRootRefusesBorrowedRecord(Mode) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml", Foreign := Folder . "\other.toml"
	Vector := _CUK_RetiredRootVector("array"), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		if Mode == "clone"
			Rows := [Rows[1].Clone()]
		else if Mode == "duplicate"
			Rows.Push(Rows[1])
		else {
			AssertEqual(1, FSWriteCreateDurable(Foreign, Source))
			Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Foreign))
		}
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000303", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertEqual(0, Result["removed"])
		AssertFalse(FileExist(Result["backup"]), "a borrowed object or file receipt refuses before backup")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: a cloned native row cannot borrow an original root receipt (config-retired-root)",
	_CUK_RetiredRootRefusesBorrowedRecord.Bind("clone"))
Test("config cleanup: equal bytes at another file cannot borrow root authority (config-retired-root)",
	_CUK_RetiredRootRefusesBorrowedRecord.Bind("foreign"))

_CUK_RetiredRootRefusesStaleSource() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("dotted"), Source := Vector["source"]
	Concurrent := StrReplace(Source, '"literal.dot" = "keep"', '"literal.dot" = "later"')
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		AssertEqual(1, FSWriteDurable(Path, Concurrent))
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000304")
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "an unchanged retired root cannot borrow changed foreign source")
		Fresh := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		Result := ConfigUnusedKeysRemove(Path, Fresh, "20990101-000305", 0, 0, Concurrent)
		AssertEqual("removed", Result["status"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(StrReplace(Vector["expected"], '"literal.dot" = "keep"', '"literal.dot" = "later"'), FSReadUtf8Exact(Path))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: stale whole-file source refuses before backup and fresh retry owns later neighbors (config-retired-root)",
	_CUK_RetiredRootRefusesStaleSource)

_CUK_RetiredRootRefusesReuse() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("inline"), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, Rows, "20990101-000306", 0, 0, Source)["status"])
		AssertEqual(1, FSWriteDurable(Path, Source), "even byte-identical restoration cannot revive consumed authority")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000307", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]))
		Fresh := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, Fresh, "20990101-000308", 0, 0, Source)["status"])
		AssertEqual(Vector["expected"], FSReadUtf8Exact(Path))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: consumed root authority cannot be replayed after byte-identical external restoration (config-retired-root)",
	_CUK_RetiredRootRefusesReuse)

_CUK_RetiredRootMutationDuringBackup(Mode) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("array"), Source := Vector["source"]
	Rows := [], Seen := Map("calls", 0)
	Backup(Target, Content) {
		Seen["calls"] += 1
		Written := FSWriteCreateDurable(Target, Content)
		switch Mode {
			case "collection": Rows.RemoveAt(1)
			case "receipt": Rows[1].Delete("retired_root_receipt")
			case "field": Rows[1]["key"] := "items"
			default: throw ValueError("Unknown backup mutation fixture")
		}
		return Written
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000309", Backup, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(1, Seen["calls"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]), "an existing verified backup cannot grant later metadata authority")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: backup-time same-map mutation refuses before source publication (config-retired-root)",
	_CUK_RetiredRootMutationDuringBackup.Bind("field"))
Test("config cleanup: backup-time preview collection mutation refuses before source publication (config-retired-root)",
	_CUK_RetiredRootMutationDuringBackup.Bind("collection"))

Test("config cleanup: backup-time removal of private receipt refuses before source publication (config-retired-root)",
	_CUK_RetiredRootMutationDuringBackup.Bind("receipt"))

_CUK_RetiredRootBackupSourceRace() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("array"), Source := Vector["source"]
	Concurrent := StrReplace(Source, '"literal.dot" = "keep"', '"literal.dot" = "later"')
	Seen := Map("calls", 0, "lease_blocked", false)
	Backup(Target, Content) {
		Seen["calls"] += 1
		Owner := _ConfigWriteLeaseTryAcquire(Path, "foreign-root-backup-probe")
		Seen["lease_blocked"] := !(Owner is Object)
		if Owner is Object
			_ConfigWriteLeaseRelease(Owner)
		Written := FSWriteCreateDurable(Target, Content)
		if !(Written is Integer) || Written != 1
			return Written
		Changed := FSWriteDurable(Path, Concurrent)
		if !(Changed is Integer) || Changed != 1
			throw Error("The native root fixture could not publish its foreign source generation")
		return Written
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_CUK_AdmitCurrentSource(Path)
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000310", Backup, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(1, Seen["calls"])
		AssertTrue(Seen["lease_blocked"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(Concurrent, FSReadUtf8Exact(Path), "the native default writer preserves the later full source")
		AssertFalse(Rows[1]["retired_root_receipt"].Consumed, "refused publication does not consume source authority")
		Owner := _ConfigWriteLeaseTryAcquire(Path, "post-root-cleanup-probe")
		try AssertTrue(Owner is Object)
		finally {
			if Owner is Object
				_ConfigWriteLeaseRelease(Owner)
		}
	} finally DirDelete(Folder, true)
}
Test("config cleanup: root capability retains the native exact-source and lease fence through backup (config-retired-root)",
	_CUK_RetiredRootBackupSourceRace)

Test("config cleanup: selecting the same whole-root receipt twice refuses before backup (config-retired-root)",
	_CUK_RetiredRootRefusesBorrowedRecord.Bind("duplicate"))
