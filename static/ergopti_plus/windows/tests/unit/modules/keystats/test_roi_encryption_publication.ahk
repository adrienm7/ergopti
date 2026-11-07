; tests/unit/modules/keystats/test_roi_encryption_publication.ahk

; ==============================================================================
; MODULE: ROI Encryption Publication Tests
; DESCRIPTION:
; Real journal writes are interrupted before and after their native append. The
; request retires unstarted text, retains numeric siblings, and waits for the
; original append's flush or acknowledged compensation without reviving rows.
; ==============================================================================

#Requires AutoHotkey v2.0

_KREP_Entry(Id, Kind := "new_trigger_candidate") {
	Entry := Map("_event_id", Id, "type", Kind, "timestamp", "2026-11-07 10:00:00", "app", "fixture-roi.exe")
	if Kind == "roi_snapshot"
		Entry["session_saved"] := 13, Entry["session_fired"] := 2
	else
		Entry["word"] := "roi-secret-marker-" . Id, Entry["occurrences"] := 5
	return Entry
}

_KREP_Request(State) {
	State["requested"] := true
	State["request_owner"] := KL_Roi_BeginEncryptionRequest(true)
	AssertTrue(IsObject(State["request_owner"]))
	MetricsFilters.encrypt := true
	AssertFalse(KL_Roi_EncryptionReady(State["port"]), "an active native journal owner prevents ON publication")
	if State["mode"] == "off" {
		MetricsFilters.encrypt := false
		KL_Roi_EndEncryptionRequest(State["request_owner"])
		State["request_owner"] := 0
	}
}

_KREP_Encode(State, Entry) {
	Line := _KL_JournalEncodeDefault(Entry)
	if !State["requested"] && (State["mode"] == "before" || State["mode"] == "off")
		_KREP_Request(State)
	return Line
}

_KREP_Append(State, Fh, Line) {
	AssertFalse(A_IsCritical, "native append must stay outside the memory claim")
	State["appends"] += 1
	Accepted := _KL_JournalAppendDefault(Fh, Line)
	if !State["requested"] {
		_KREP_Request(State)
		if State["mode"] == "rollback" || State["mode"] == "debt"
			return false
	}
	return Accepted
}

_KREP_Repair(State, Fh, Boundary) {
	AssertFalse(A_IsCritical, "only the existing owner performs native compensation")
	State["repairs"] += 1
	if State["mode"] == "debt" && !State["repair_allowed"]
		return false
	return _KL_JournalRollbackAppend(Fh, Boundary, FSFlushFileBuffers)
}

_KREP_Journal(Mode) {
	global KL_ENC_Enabled
	SavedKnown := KLRoiPrivacy.canonical_known
	KL_Roi_SetCanonicalPolicyKnown(true)
	Saved := [MetricsFilters.encrypt, KL_ENC_Enabled, Keystats._pending_entries,
		KLRoiPrivacy.epoch, KLRoiPrivacy.blocked, KLRoiPrivacy.started, KLRoiPrivacy.request_owner]
	Path := _FSWL_Path() . "-roi-encryption"
	Fh := 0, Owner := KL_JournalOwner()
	State := Map("mode", Mode, "requested", false, "request_owner", 0,
		"appends", 0, "repairs", 0, "repair_allowed", false)
	try {
		MetricsFilters.encrypt := false
		KL_ENC_Enabled := false
		KLRoiPrivacy.blocked := false
		KLRoiPrivacy.started := Map()
		KLRoiPrivacy.request_owner := 0
		First := _KREP_Entry(901), Second := _KREP_Entry(902), Numeric := _KREP_Entry(903, "roi_snapshot")
		Keystats._pending_entries := [First, Second, Numeric]
		Fh := FileOpen(Path, "w", "UTF-8-RAW")
		Port := Map("owner", Owner, "open", (*) => Fh, "encode", _KREP_Encode.Bind(State),
			"append", _KREP_Append.Bind(State), "rollback", _KREP_Repair.Bind(State))
		State["port"] := Port
		Result := _KL_JournalPendingEntries(Port)
		if Mode == "rollback" || Mode == "debt" {
			AssertFalse(Result["ok"])
			AssertEqual(Mode == "debt", Owner.HasDebt())
			if Mode == "debt" {
				RepairsBefore := State["repairs"]
				AssertFalse(KL_Roi_EncryptionReady(Port))
				AssertEqual(RepairsBefore, State["repairs"], "a preference request must never initiate compensation")
				AssertEqual(1, KLRoiPrivacy.started.Count, "the unacknowledged append keeps its exact row")
				MetricsFilters.encrypt := false
				KL_Roi_EndEncryptionRequest(State["request_owner"])
				State["request_owner"] := 0
				AssertTrue(KL_Roi_CommitEncryptionPolicy(false))
				AssertTrue(KLRoiPrivacy.blocked, "an OFF refresh cannot reopen text over unresolved compensation")
				AssertFalse(KL_Roi_AdmitTextEntry(_KREP_Entry(914)))
				AssertFalse(_KL_JournalPendingEntries(Port)["ok"])
				State["repair_allowed"] := true
			}
			Result := _KL_JournalPendingEntries(Port)
		}
		AssertTrue(Result["ok"])
		AssertFalse(Owner.HasDebt())
		AssertEqual(0, KLRoiPrivacy.started.Count)
		AssertTrue(KL_Roi_EncryptionReady(Port), "settled native ownership permits the preference to publish")
		Fh.Close(), Fh := 0
		Disk := FileRead(Path, "UTF-8")
		AssertEqual(Mode == "after", !!InStr(Disk, "roi-secret-marker-901"),
			"only the append already started before ON may reach the durable journal")
		AssertFalse(InStr(Disk, "roi-secret-marker-902"), "the unstarted detached suffix is retired")
		AssertContains(Disk, '"session_saved":13', "numeric ROI survives the text policy")
		AssertFalse(InStr(Disk, "_KL_RoiCaptureEpoch"), "capture authority is not serialized as telemetry")
		AssertEqual(0, Keystats._pending_entries.Length)
		if IsObject(State["request_owner"]) {
			KL_Roi_EndEncryptionRequest(State["request_owner"])
			State["request_owner"] := 0
		}
		MetricsFilters.encrypt := false
		AssertTrue(KL_Roi_CommitEncryptionPolicy(false))
		AssertFalse(KL_Roi_AdmitTextEntry(Second), "OFF must not resurrect any old unstarted row")
		AssertTrue(KL_Roi_AdmitTextEntry(_KREP_Entry(904)), "a new OFF capture remains available")
	} finally {
		State["repair_allowed"] := true
		if Owner.HasDebt() {
			Token := Owner.Acquire()
			AssertTrue(IsObject(Token), "fixture cleanup requires the actual compensation acknowledgement")
			Owner.Release(Token)
		}
		if IsObject(Fh)
			Fh.Close()
		if FileExist(Path)
			FileDelete(Path)
		KLRoiPrivacy.canonical_known := SavedKnown
		MetricsFilters.encrypt := Saved[1], KL_ENC_Enabled := Saved[2]
		Keystats._pending_entries := Saved[3]
		KLRoiPrivacy.epoch := Saved[4], KLRoiPrivacy.blocked := Saved[5]
		KLRoiPrivacy.started := Saved[6], KLRoiPrivacy.request_owner := Saved[7]
	}
}

for _KREP_Mode in ["before", "off", "after", "rollback", "debt"]
	Test("ROI encryption: " . _KREP_Mode . " preserves exact native publication ownership (roi-encryption-publication)",
		_KREP_Journal.Bind(_KREP_Mode))

_KREP_UnknownPolicy() {
	global KL_ENC_Enabled
	SavedKnown := KLRoiPrivacy.canonical_known
	KL_Roi_SetCanonicalPolicyKnown(true)
	Saved := [MetricsFilters.encrypt, KL_ENC_Enabled, Keystats._pending_entries,
		KLRoiPrivacy.epoch, KLRoiPrivacy.blocked, KLRoiPrivacy.started, KLRoiPrivacy.request_owner]
	try {
		KLRoiPrivacy.started := Map(), KLRoiPrivacy.request_owner := 0
		for Policy in [[true, false], ["unknown", false], [false, "unknown"], [false, true]] {
			MetricsFilters.encrypt := false, KL_ENC_Enabled := false, KLRoiPrivacy.blocked := false
			Entry := _KREP_Entry(910)
			AssertTrue(KL_Roi_AdmitTextEntry(Entry))
			Keystats._pending_entries := [Entry, _KREP_Entry(911, "roi_snapshot")]
			MetricsFilters.encrypt := Policy[1], KL_ENC_Enabled := Policy[2]
			AssertFalse(KL_Roi_TextAllowed(), "requested ON and unknown cipher states cannot publish words")
			AssertEqual(1, Keystats._pending_entries.Length)
			AssertEqual("roi_snapshot", Keystats._pending_entries[1]["type"])
			AssertFalse(KL_Roi_AdmitTextEntry(_KREP_Entry(912)))
			AssertTrue(KL_Roi_AdmitTextEntry(_KREP_Entry(913, "roi_snapshot")))
		}
	} finally {
		KLRoiPrivacy.canonical_known := SavedKnown
		MetricsFilters.encrypt := Saved[1], KL_ENC_Enabled := Saved[2], Keystats._pending_entries := Saved[3]
		KLRoiPrivacy.epoch := Saved[4], KLRoiPrivacy.blocked := Saved[5]
		KLRoiPrivacy.started := Saved[6], KLRoiPrivacy.request_owner := Saved[7]
	}
}
Test("ROI encryption: only known OFF preference and cipher admit textual rows (roi-encryption-publication)",
	_KREP_UnknownPolicy)

; The genuine JSON encoder enumerates this real Map. Its one callback provides
; a deterministic interruption without replacing the ingest, append or SQL code.
class _KREP_ObservedEntry extends Map {
	__Enum(Variables) {
		if this.HasOwnProp("Observe") && IsObject(this.Observe) {
			Callback := this.Observe
			this.Observe := 0
			Callback.Call()
		}
		return super.__Enum(Variables)
	}
}

_KREP_IngestRequest(State) {
	State["request_owner"] := KL_Roi_BeginEncryptionRequest(true)
	AssertTrue(IsObject(State["request_owner"]))
	MetricsFilters.encrypt := true
	AssertFalse(KL_Roi_EncryptionReady(), "the real ingest owner blocks preference publication")
	if State["mode"] == "rollback"
		throw Error("fixture encoding refusal after native prefix")
}

_KREP_Ingest(Mode) {
	global KL_ENC_Enabled
	SavedKnown := KLRoiPrivacy.canonical_known
	KL_Roi_SetCanonicalPolicyKnown(true)
	SavedPolicy := [MetricsFilters.encrypt, KL_ENC_Enabled, KLRoiPrivacy.epoch,
		KLRoiPrivacy.blocked, KLRoiPrivacy.started, KLRoiPrivacy.request_owner]
	Names := ["initialized", "_shutting_down", "today_log_path", "today_log_offset",
		"today_log_date", "state_json_path", "data_sql_path", "_today_fh", "_today_fh_date",
		"_pending_entries", "next_event_id", "data_sql_receipt"]
	Saved := Map()
	for Name in Names
		if Keystats.HasOwnProp(Name)
			Saved[Name] := Keystats.%Name%
	Windows := KLWV.windows
	Root := _FSWL_Path() . "-roi-ingest"
	Db := 0, OwnsRoot := false, OwnsJournal := false
	State := Map("mode", Mode, "request_owner", 0)
	try {
		DirCreate(Root), OwnsRoot := true
		MetricsFilters.encrypt := false, KL_ENC_Enabled := false
		KLRoiPrivacy.blocked := false, KLRoiPrivacy.started := Map(), KLRoiPrivacy.request_owner := 0
		Keystats.initialized := true, Keystats._shutting_down := false
		Keystats.today_log_path := Root . "\today.log", Keystats.today_log_offset := 0
		Keystats.today_log_date := KL_Today(), Keystats.state_json_path := Root . "\state.json"
		Keystats.data_sql_path := Root . "\data.sql", Keystats._today_fh := unset
		OwnsJournal := true
		Keystats._today_fh_date := "", Keystats.next_event_id := 1000
		KLWV.windows := Map()
		Observed := _KREP_ObservedEntry()
		for Key, Value in _KREP_Entry(902)
			Observed[Key] := Value
		Observed.Observe := _KREP_IngestRequest.Bind(State)
		First := _KREP_Entry(901), Numeric := _KREP_Entry(903, "roi_snapshot")
		Keystats._pending_entries := Mode == "before" ? [Observed, First, Numeric] : [First, Observed, Numeric]
		Historical := _KREP_Entry(899)
		FileAppend(KL_JsonEncode(Historical) . "`n", Keystats.today_log_path, "UTF-8-RAW")
		FileAppend("-- prior`n", Keystats.data_sql_path, "UTF-8-RAW")
		AssertTrue(KL_SaveState())
		Result := KL_IngestOnce(true, true)
		if Mode == "rollback" {
			AssertFalse(Result["ok"])
			AssertEqual("today_log_append_failed", Result["reason"])
			AssertEqual(1, Keystats._pending_entries.Length, "the dense retry suffix retains only the numeric row")
			Result := KL_IngestOnce(true, true)
		}
		AssertTrue(Result["ok"])
		AssertTrue(KL_Roi_EncryptionReady())
		AssertEqual(FileGetSize(Keystats.today_log_path), Keystats.today_log_offset)
		Sql := FileRead(Keystats.data_sql_path, "UTF-8")
		Journal := FileRead(Keystats.today_log_path, "UTF-8")
		AssertContains(Sql, "roi-secret-marker-899", "historical journal events must retain their original capture policy")
		AssertEqual(Mode == "after", !!InStr(Sql, "roi-secret-marker-901"))
		AssertFalse(InStr(Sql, "roi-secret-marker-902"))
		AssertFalse(InStr(Journal, "roi-secret-marker-902"))
		AssertFalse(InStr(Sql, "_KL_RoiCaptureEpoch"))
		Db := _WJFM_OpenMemory()
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(SQLite_Exec(Db, Sql))
		AssertEqual(Mode == "after" ? 3 : 2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_roi;")[1]["n"])
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_roi WHERE kind='roi_snapshot';")[1]["n"])
		AssertTrue(KL_IngestOnce(true, true)["ok"])
		AssertEqual(Sql, FileRead(Keystats.data_sql_path, "UTF-8"), "a settled ingest remains exactly once")
	} finally {
		if Db
			SQLite_Close(Db)
		if OwnsJournal && Keystats.HasOwnProp("_today_fh") && IsObject(Keystats._today_fh)
			Keystats._today_fh.Close()
		for Name in Names {
			if Saved.Has(Name)
				Keystats.%Name% := Saved[Name]
			else if Keystats.HasOwnProp(Name)
				Keystats.DeleteProp(Name)
		}
		KLWV.windows := Windows
		KLRoiPrivacy.canonical_known := SavedKnown
		MetricsFilters.encrypt := SavedPolicy[1], KL_ENC_Enabled := SavedPolicy[2]
		KLRoiPrivacy.epoch := SavedPolicy[3], KLRoiPrivacy.blocked := SavedPolicy[4]
		KLRoiPrivacy.started := SavedPolicy[5], KLRoiPrivacy.request_owner := SavedPolicy[6]
		if OwnsRoot && DirExist(Root)
			DirDelete(Root, true)
	}
}

for _KREP_IngestMode in ["before", "after", "rollback"]
	Test("ROI encryption: actual ingestion " . _KREP_IngestMode . " preserves history and dense retries (roi-encryption-publication)",
		_KREP_Ingest.Bind(_KREP_IngestMode))

_KREP_CanonicalPolicy() {
	global _ConfigDir, _AhkSubDir, _ConfigBootReadFailed
	SavedDir := _ConfigDir, SavedSubdir := _AhkSubDir
	SavedReadFailure := _ConfigBootReadFailed
	SavedRuntime := _CSTT_SaveRuntime()
	SavedPrivacy := [KLRoiPrivacy.epoch, KLRoiPrivacy.blocked, KLRoiPrivacy.started,
		KLRoiPrivacy.request_owner, Keystats._pending_entries]
	Root := _FSWL_Path() . "-roi-policy\"
	DirCreate(Root)
	try {
		_AhkSubDir := ""
		KLRoiPrivacy.started := Map(), KLRoiPrivacy.request_owner := 0
		for Index, Raw in ['encrypt = "true"', "encrypt = false", ""] {
			_ConfigDir := Root . Index . "\"
			Path := CS_GetTomlPath()
			_CSTT_WriteConfig(Path, Raw)
			Before := FSReadUtf8Exact(Path)
			CS_Load()
			AssertFalse(MetricsFilters.encrypt, "the existing metrics reader keeps its manifest-compatible value")
			AssertEqual(Index != 1, KLRoiPrivacy.canonical_known,
				"ROI must distinguish a malformed raw preference from a legitimate absent leaf")
			AssertEqual(Index != 1, KL_Roi_TextAllowed())
			AssertEqual(Before, FSReadUtf8Exact(Path), "policy observation never rewrites the user source")
		}
		_ConfigDir := Root . "unreadable\"
		Path := CS_GetTomlPath()
		DirCreate(Path)
		CS_Load()
		AssertTrue(_ConfigBootReadFailed, "the actual source owner must refuse the unreadable native path")
		AssertFalse(KLRoiPrivacy.canonical_known)
		AssertFalse(KL_Roi_TextAllowed(), "a failed real configuration read cannot authorize ROI text")
		MetricsFiltersApplyManifestDefaults()
		AssertFalse(KL_Roi_TextAllowed(), "default initialization cannot reopen an unknown canonical policy")
	} finally {
		_CSTT_RestoreRuntime(SavedRuntime)
		KLRoiPrivacy.epoch := SavedPrivacy[1], KLRoiPrivacy.blocked := SavedPrivacy[2]
		KLRoiPrivacy.started := SavedPrivacy[3], KLRoiPrivacy.request_owner := SavedPrivacy[4]
		Keystats._pending_entries := SavedPrivacy[5]
		_ConfigDir := SavedDir, _AhkSubDir := SavedSubdir
		_ConfigBootReadFailed := SavedReadFailure
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("ROI encryption: actual raw config keeps malformed policy unknown (roi-encryption-publication)",
	_KREP_CanonicalPolicy)
