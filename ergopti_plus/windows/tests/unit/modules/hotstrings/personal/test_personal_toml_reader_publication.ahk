; tests/unit/modules/hotstrings/personal/test_personal_toml_reader_publication.ahk
; A returning parse must not repopulate the menu/editor cache after a newer
; public read or a completed real rewrite has already established the winner.
#Requires AutoHotkey v2.0

class _PTRP_Fixture {
	__New(Mode, Path) {
		this.Mode := Mode
		this.Path := Path
		this.LogCalls := 0
		this.TimerCalls := 0
		this.Done := false
		this.Failure := 0
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
	}
	OnLog(Line) {
		if !InStr(Line, "[WARNING] [PersonalToml] Metadata source in", true)
			return
		this.LogCalls += 1
		if this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the existing metadata diagnostic must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the real timer must finish before the old diagnostic returns")
		} catch as Failure
			this.Failure := Failure
	}
	OnTimer() {
		global _ReadPersonalTomlCache
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical)
			if this.Mode != "live" {
				; An external repair is a real file producer. The replacement is valid
				; before either canonical reader or writer admits it; the old malformed
				; image is never passed off as an acknowledged writer precondition.
				AssertEqual(1, FSWriteDurable(this.Path, _PTRP_Image("Winner", false)))
				this.Winner := ReadPersonalToml(true)
				AssertEqual("Winner", this.Winner["sections"]["alpha"]["entries"][1]["output"],
					"the newer public reader must admit the actual repaired source")
				if this.Mode == "commit" {
					Candidate := _PersonalTomlCloneDetached(this.Winner)
					Candidate["sections"]["alpha"]["entries"][1]["output"] := "Committed"
					this.Result := WritePersonalToml(Candidate)
					AssertTrue(this.Result is Integer && this.Result == 1,
						"the real public writer must acknowledge its actual durable rewrite")
					AssertFalse(_ReadPersonalTomlCache,
						"the completed writer must really evict the newer reader's cache")
				}
			}
			this.Bytes := FSReadBytesStrict(this.Path)
		} catch as Failure
			this.Failure := Failure
		finally this.Done := true
	}
	Exercise() {
		global _ReadPersonalTomlCache
		AssertEqual(1, FSWriteDurable(this.Path, _PTRP_Image("Older parse", true)))
		AssertFalse(_ReadPersonalTomlCache, "the old read must begin without a resident model")
		LoggerSetTestSink(this.SinkFn)
		Older := ReadPersonalToml(true)
		LoggerClearTestSink()
		if this.Failure is Error
			throw this.Failure
		AssertEqual(1, this.LogCalls, "the genuine malformed-metadata diagnostic must run once")
		AssertEqual(1, this.TimerCalls, "one genuine timer must interrupt that diagnostic")
		AssertEqual("Older parse", Older["sections"]["alpha"]["entries"][1]["output"],
			"the detached result still describes the exact source that this call parsed")
		; Menus and section projections use this public non-refresh call. The old
		; implementation fails on a stale displayed expansion, before any assertion
		; about new revision bookkeeping could manufacture a missing-helper failure.
		Current := ReadPersonalToml()
		Expected := this.Mode == "live" ? "Older parse" : this.Mode == "commit" ? "Committed" : "Winner"
		AssertEqual(Expected, Current["sections"]["alpha"]["entries"][1]["output"],
			"a returning old parse cannot replace the newer personal hotstring seen by menus")
		if this.Mode == "read"
			AssertTrue(Current == this.Winner, "the exact newer admitted model must retain cache ownership")
		AssertTrue(Current == _ReadPersonalTomlCache)
		_PTRP_Bytes(this.Bytes, FSReadBytesStrict(this.Path),
			"finishing a read must preserve the exact repaired or committed source")
		Again := ReadPersonalToml()
		AssertEqual(Expected, Again["sections"]["alpha"]["entries"][1]["output"])
		AssertEqual(1, this.LogCalls, "the current cache must not parse the stale diagnostic again")
		Lease := _PersonalTomlWriteLeaseTryAcquire(this.Path, "personal-toml-reader-control")
		AssertTrue(Lease is Object)
		try AssertTrue(_PersonalTomlWriteLeaseOwns(Lease, this.Path))
		finally _PersonalTomlWriteLeaseRelease(Lease)
		Stages := 0
		loop files, this.Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	}
	Close() {
		SetTimer(this.TimerFn, 0)
		this.TimerFn := 0
		this.SinkFn := 0
	}
}

_PTRP_Image(Output, BrokenMetadata) {
	Description := BrokenMetadata ? 'description = "unterminated' : 'description = "Admitted source"'
	return "[_meta]`n" . Description . '`n[[alpha]]`n"zz" = { output = "' . Output
		. '", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
}

_PTRP_Bytes(Expected, Actual, Message) {
	AssertTrue(Expected is Buffer && Actual is Buffer, Message)
	AssertEqual(Expected.Size, Actual.Size, Message)
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, Message)
}

_PTRP_Case(Mode) {
	global ScriptInformation, _ReadPersonalTomlCache, _HS_GrandTotalCache, _TomlUnreadableFiles
	global _PersonalTomlReadGeneration, _HealthCheckWarnCount
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	static Sequence := 0
	AssertFalse(A_IsSuspended)
	AssertEqual(0, _LOGGER_TEST_SINK, "the fixture cannot replace a foreign observer")
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	Saved := {Cache: _ReadPersonalTomlCache, GrandTotal: _HS_GrandTotalCache,
		HadPath: ScriptInformation.Has("PersonalTomlPath"), Path: ScriptInformation.Get("PersonalTomlPath", ""),
		HadGeneration: IsSet(_PersonalTomlReadGeneration), HadWarnings: IsSet(_HealthCheckWarnCount),
		Repeat: _LOGGER_REPEAT_ENABLED, PathDate: _LOGGER_PATH_DATE}
	Saved.Generation := Saved.HadGeneration ? _PersonalTomlReadGeneration : 0
	Saved.Warnings := Saved.HadWarnings ? _HealthCheckWarnCount : 0
	Root := A_Temp . "\ergopti_personal_toml_reader_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	Path := Root . "\personal_hotstrings.toml"
	FSCreateDirectoryExclusiveStrict(Root)
	F := _PTRP_Fixture(Mode, Path), Primary := 0, CleanupError := 0
	PreviousCritical := A_IsCritical
	try {
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false
		_LOGGER_PATH_DATE := ""
		Critical("Off")
		F.Exercise()
	} catch as Failure {
		Primary := Failure
	} finally {
		try F.Close()
		catch as Failure {
			CleanupError := Failure
		} finally {
			_LOGGER_TEST_SINK := 0
			_LOGGER_REPEAT_ENABLED := Saved.Repeat
			_LOGGER_PATH_DATE := Saved.PathDate
			_TLOG_RestoreLoggerState(SavedLogger)
			try _ParseTomlGroupConfig_InvalidatePath(Path)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
			_ReadPersonalTomlCache := Saved.Cache
			_HS_GrandTotalCache := Saved.GrandTotal
			_PersonalTomlReadGeneration := Saved.HadGeneration ? Saved.Generation : unset
			_HealthCheckWarnCount := Saved.HadWarnings ? Saved.Warnings : unset
			if Saved.HadPath
				ScriptInformation["PersonalTomlPath"] := Saved.Path
			else
				ScriptInformation.Delete("PersonalTomlPath")
			if IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path)
				_TomlUnreadableFiles.Delete(Path)
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

Test("personal hotstring reader: a newer public read retains its menu model (personal-toml-reader-publication)",
	_PTRP_Case.Bind("read"))
Test("personal hotstring reader: a repaired committed source survives an older parse (personal-toml-reader-publication)",
	_PTRP_Case.Bind("commit"))
Test("personal hotstring reader: uninterrupted diagnostic retains its model (personal-toml-reader-publication)",
	_PTRP_Case.Bind("live"))
