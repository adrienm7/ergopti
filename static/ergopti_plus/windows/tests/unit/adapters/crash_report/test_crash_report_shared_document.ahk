; tests/unit/adapters/crash_report/test_crash_report_shared_document.ahk

; ==============================================================================
; MODULE: Crash Report Shared Document Tests
; DESCRIPTION:
; Replays _shared/tests/corpus/diagnostics/crash_report_vectors.json, the vectors
; of _shared/lua/crash_report.lua, against the Windows reporter. Windows used to
; write its own field names, a local timestamp and a GUID in the file name, and
; kept every report forever, so a reader had to branch on the driver and the crash
; folder grew without bound.
; ==============================================================================

#Requires AutoHotkey v2.0

_CRSD_Corpus() {
	global _SharedDir
	Data := JsonParse(FileRead(_SharedDir . "\tests\corpus\diagnostics\crash_report_vectors.json", "UTF-8"))
	Assert(Data["fields"].Length > 20 && Data["retention"].Length >= 5, "the corpus must hold its vectors")
	return Data
}

_CRSD_Fields() {
	Data := _CRSD_Corpus()
	AssertEqual(Data["max_reports"], CRASH_REPORT_MAX_REPORTS, "the cap")
	AssertEqual(Data["fields"].Length, CRASH_REPORT_FIELDS.Length, "the field count")
	for Index, Name in Data["fields"]
		AssertEqual(Name, CRASH_REPORT_FIELDS[Index][1], "field " . Index . " of the shared order")
}
Test("crash report: the fields and the cap are the shared ones (crash-report-shared-document)", _CRSD_Fields)

_CRSD_Names() {
	Data := _CRSD_Corpus()
	for Vector in Data["stems"]
		AssertEqual(Vector["stem"], _CrashReport_Stem(Vector["timestamp"]), Vector["timestamp"])
	for Vector in Data["names"] {
		AssertEqual(Vector["name"], _CrashReport_FileName(Vector["stem"], Vector["attempt"]), Vector["name"])
		Parsed := _CrashReport_ParseName(Vector["name"])
		Assert(Parsed is Map, Vector["name"] . " is a report name")
		AssertEqual(Vector["stem"], Parsed["stem"], Vector["name"])
		AssertEqual(Vector["attempt"], Parsed["attempt"], Vector["name"])
	}
	for Name in Data["not_report_names"]
		AssertEqual(0, _CrashReport_ParseName(Name), "'" . Name . "' is not a report name")
	AssertThrows(() => _CrashReport_Stem("2026-10-25 21:04:11"), "a local timestamp is refused")
}
Test("crash report: the file names are the shared ones (crash-report-shared-document)", _CRSD_Names)

_CRSD_Retention() {
	for Vector in _CRSD_Corpus()["retention"] {
		Got := CrashReport_ExpiredNames(Vector["names"], Vector["limit"])
		AssertEqual(Vector["expired"].Length, Got.Length, Vector["case"])
		for Index, Name in Vector["expired"]
			AssertEqual(Name, Got[Index], Vector["case"])
	}
}
Test("crash report: retention selects the shared oldest reports (crash-report-shared-document)", _CRSD_Retention)

_CRSD_Documents() {
	for Vector in _CRSD_Corpus()["documents"]
		AssertEqual(Vector["json"], _CrashReport_ToJson(Vector["fields"]), Vector["case"])
}
Test("crash report: the document is byte for byte the shared one (crash-report-shared-document)", _CRSD_Documents)

_CRSD_OwnFieldsFollow() {
	Parsed := _CrashReport_ToJson(Map("version", "1", "cpu_name", "the cpu"))
	Assert(InStr(Parsed, '"log_tail"') < InStr(Parsed, '"cpu_name"'),
		"what only this driver knows follows the shared fields")
	AssertEqual("the cpu", JsonParse(Parsed)["cpu_name"], "the driver's own detail is kept")
}
Test("crash report: this driver's own fields follow the shared ones (crash-report-shared-document)", _CRSD_OwnFieldsFollow)

_CRSD_PruneKeepsTheNewestReports() {
	global _LogsDir
	Saved := _LogsDir
	Root := _SR_AcquireCaptureDirectory()
	try {
		_LogsDir := Root
		Dir := LoggerCrashReportsDir()
		DirCreate(Dir)
		Limit := CRASH_REPORT_MAX_REPORTS
		Loop Limit + 3
			FileAppend("{}", Dir . Format("2026-10-25T10-00-{:02}Z.json", A_Index), "UTF-8")
		FileAppend("{}", Dir . "notes.json", "UTF-8")
		AssertEqual(3, CrashReport_PruneReports(), "the three oldest go")
		AssertFalse(FileExist(Dir . "2026-10-25T10-00-03Z.json"), "the oldest are deleted")
		Assert(FileExist(Dir . "2026-10-25T10-00-04Z.json"), "the newest stay")
		Assert(FileExist(Dir . "notes.json"), "a stray file is never selected")
		Path := CrashReport_Save(Map("timestamp", "2026-10-25T11:00:00Z", "error_msg", "newest"))
		AssertEqual(Dir . "2026-10-25T11-00-00Z.json", Path, "the shared name")
		AssertEqual(Dir . "2026-10-25T11-00-00Z-2.json",
			CrashReport_Save(Map("timestamp", "2026-10-25T11:00:00Z", "error_msg", "same second")),
			"a second report within the same second takes the suffix")
		AssertFalse(FileExist(Dir . "2026-10-25T10-00-05Z.json"), "a save enforces the cap")
	} finally {
		_LogsDir := Saved
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("crash report: a save keeps the newest reports and never a stray file (crash-report-shared-document)",
	_CRSD_PruneKeepsTheNewestReports)
