; tests/meta/adapters/crash_report/test_crash_report_unique_filename.ahk

; ==============================================================================
; MODULE: Crash Report Unique Filename Meta Test
; DESCRIPTION:
; Static source guard for the "same-second crash report filename collision"
; finding (crash-report-same-second-collision).
;
; modules/diagnostics/crash_reporter.ahk previously derived the filename from a second-resolution
; timestamp and wrote with FileAppend. Two crashes within the same second would
; open the same path and append, producing concatenated JSON objects (}{) in one
; file — invalid JSON that no parser can consume.
;
; The fix introduces a uniqueness loop (FileExist + numeric suffix) and replaces
; FileAppend with FileOpen("w") (truncating write) so each report always lands in
; its own, newly-created file. These tests assert the fix is present and the
; buggy form is absent.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Uniqueness loop assertions ==========
; ================================================
; ================================================

_CRUN_HasFileExistLoop() {
	; Move-resilient: scan the module tree via the framework helper instead of
	; a pinned crash_reporter path. The FName/JsonStr tokens are unique to
	; crash_reporter within modules/diagnostics/, so the scope stays meaningful.
	Src := _DriverDirConcat("modules/diagnostics")
	Assert(InStr(Src, "FileExist(FName)") > 0,
		"crash_reporter.ahk must contain a FileExist(FName) uniqueness loop to handle same-second collisions")
}
Test("crash_reporter: CrashReport_Save contains FileExist uniqueness loop (crash-report-same-second-collision)", _CRUN_HasFileExistLoop)

_CRUN_UsesCompleteDurableWrite() {
	Body := _DriverFuncBody("CrashReport_Save")
	Assert(Body != "", "CrashReport_Save must remain reachable")
	Assert(InStr(Body, "FSWriteCreateDurable") > 0,
		"a crash report must require exclusive creation, complete UTF-8 bytes and a stable-storage receipt (AHK-087)")
	Assert(InStr(Body, ".Write(JsonStr)") = 0,
		"CrashReport_Save must not acknowledge an unchecked File.Write result")
}
Test("crash_reporter: CrashReport_Save requires a complete durable write (AHK-087)",
	_CRUN_UsesCompleteDurableWrite)

_CRUN_WriterRefusalCannotPublishSuccess() {
	global _LogsDir
	SavedLogsDir := _LogsDir
	Root := A_Temp . "\ergopti_crash_report_refusal_" . A_TickCount . "\"
	WriterCalls := 0
	ObservedPath := ""

	_RefuseWriter(Path, Content) {
		WriterCalls += 1
		ObservedPath := Path
		return false
	}

	try {
		; The logger's resolver names the crash-reports folder inside the logs folder.
		_LogsDir := Root
		Result := CrashReport_Save(Map(
			"timestamp", "2026-08-28T20:30:00Z",
			"driver", "autohotkey"), _RefuseWriter)
		Assert(Result = "" && WriterCalls = 1,
			"a refused durable writer must make CrashReport_Save fail instead of returning a success path")
		Assert(ObservedPath != "" && !FileExist(ObservedPath),
			"a failed crash report must leave no partial JSON artifact behind")
		Assert(InStr(ObservedPath, Root . "crash_reports\") == 1,
			"the report must be written in the crash_reports folder inside the logs folder")
	} finally {
		_LogsDir := SavedLogsDir
		try DirDelete(Root, true)
	}
}
Test("crash_reporter: writer refusal cannot publish a false success (AHK-087)",
	_CRUN_WriterRefusalCannotPublishSuccess)

_CRUN_NoFileAppend() {
	Src := _DriverDirConcat("modules/diagnostics")
	Assert(InStr(Src, "FileAppend(JsonStr") = 0,
		"crash_reporter.ahk must NOT use FileAppend for crash reports — same-second writes corrupt the JSON file")
}
Test("crash_reporter: CrashReport_Save does not use FileAppend (crash-report-same-second-collision)", _CRUN_NoFileAppend)


_CRUN_ReentrantSavePreservesBothIncidents() {
	global _LogsDir
	SavedLogsDir := _LogsDir
	Root := A_Temp . "\ergopti_crash_reentrant_" . A_ScriptHwnd . "_" . A_TickCount . "\"
	InnerPath := ""
	Timestamp := "2026-10-25T17:00:00Z"
	_InterleaveBeforeWrite(Path, Content) {
		; The serializer and writer can pump another deferred crash. Both writes
		; use the actual durable filesystem adapter; no result is synthesized.
		InnerPath := CrashReport_Save(Map("timestamp", Timestamp, "error_msg", "inner incident"))
		return FSWriteDurable(Path, Content)
	}
	try {
		_LogsDir := Root
		OuterPath := CrashReport_Save(Map("timestamp", Timestamp, "error_msg", "outer incident"),
			_InterleaveBeforeWrite)
		AssertTrue(InnerPath != "" && OuterPath != "", "both actual saves must acknowledge durable bytes")
		AssertTrue(InnerPath != OuterPath, "reentrant incidents must own distinct paths before either writer yields")
		AssertEqual("inner incident", JsonParse(FileRead(InnerPath, "UTF-8"))["error_msg"],
			"the outer save must not replace the already-acknowledged inner artifact")
		AssertEqual("outer incident", JsonParse(FileRead(OuterPath, "UTF-8"))["error_msg"])
	} finally {
		_LogsDir := SavedLogsDir
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("crash_reporter: reentrant saves preserve both actual incident artifacts (crash-report-reentrant-save)",
	_CRUN_ReentrantSavePreservesBothIncidents)


; A report is a Map. Its first canonical field read happens after the caller's
; filename probe, allowing an independent JSON writer to win that native path.
class _CRUN_ExternalCollisionReport extends Map {
	__New(Timestamp, Path, Bytes) {
		super.__New("timestamp", Timestamp, "version", "collision-control", "error_msg", "competing report")
		this.CollisionPath := Path
		this.CollisionBytes := Bytes
		this.Created := 0
	}
	__Item[Key] {
		get {
			if Key == "version" && !this.Created {
				AssertFalse(FileExist(this.CollisionPath), "the competing writer must win only after the free-path probe")
				AssertEqual(1, FSWriteCreateDurable(this.CollisionPath, this.CollisionBytes),
					"an independent native CREATE_NEW must publish the sentinel JSON")
				this.Created += 1
			}
			return super[Key]
		}
	}
}

_CRUN_DefaultWriterPreservesExternalCollision() {
	global _LogsDir
	SavedLogsDir := _LogsDir
	Root := _SR_AcquireCaptureDirectory()
	Timestamp := "2026-10-25T17:00:00Z"
	Sentinel := '{"origin":"independent JSON writer"}'
	try {
		_LogsDir := Root
		Baseline := CrashReport_Save(Map("timestamp", Timestamp, "error_msg", "baseline incident"))
		AssertTrue(Baseline != "" && FileExist(Baseline), "the default writer must first acknowledge a genuine baseline artifact")
		AssertTrue(RegExMatch(Baseline, "_([0-9]+)_([0-9]+)\.json$", &Identity),
			"the public acknowledged filename must expose its process-local identity")
		Prefix := LoggerCrashReportsDir() . "2026-10-25T17-00-00Z_"
		AssertEqual(Prefix . DllCall("GetCurrentProcessId", "UInt") . "_" . Identity[2] . ".json", Baseline,
			"prediction must qualify against the actual default-writer baseline path")
		CollisionPath := Prefix . Identity[1] . "_" . (Integer(Identity[2]) + 1) . ".json"
		AssertFalse(FileExist(CollisionPath), "the predicted next public filename must initially be absent")
		Report := _CRUN_ExternalCollisionReport(Timestamp, CollisionPath, Sentinel)
		Result := CrashReport_Save(Report)
		AssertEqual(1, Report.Created, "the ordinary report-field read must reach the real competing file writer")
		AssertEqual(Sentinel, FileRead(CollisionPath, "UTF-8"), "the production writer cannot replace independently created JSON bytes")
		AssertEqual("", Result, "a collision after probing must return explicit refusal instead of acknowledging a foreign artifact")
		Next := CrashReport_Save(Map("timestamp", Timestamp, "error_msg", "after collision"))
		AssertTrue(Next != "" && Next != CollisionPath, "a later default save must still acknowledge its own distinct artifact")
		AssertEqual("after collision", JsonParse(FileRead(Next, "UTF-8"))["error_msg"])
		AssertEqual("baseline incident", JsonParse(FileRead(Baseline, "UTF-8"))["error_msg"])
		AssertEqual(Sentinel, FileRead(CollisionPath, "UTF-8"), "the successful successor must preserve the independent sentinel too")
	} finally {
		_LogsDir := SavedLogsDir
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("crash_reporter: default writer refuses an external JSON collision without replacing bytes (crash-report-native-collision)",
	_CRUN_DefaultWriterPreservesExternalCollision)
