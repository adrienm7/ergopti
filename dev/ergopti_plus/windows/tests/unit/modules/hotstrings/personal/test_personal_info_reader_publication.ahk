; tests/unit/modules/hotstrings/personal/test_personal_info_reader_publication.ahk
; A diagnostic from an older parse may pump a newer public read or durable save.
; The returning reader must not replace that admitted identity with its old image.
#Requires AutoHotkey v2.0

class _PIRP_Fixture {
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
		if !InStr(Line, "Ignoring duplicate personal-info letter alias", true)
			return
		this.LogCalls += 1
		if this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the real parser diagnostic must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the native timer must finish before the old diagnostic returns")
		} catch as Failure
			this.Failure := Failure
	}
	OnTimer() {
		global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
		global HSE_RuntimeDecisionGeneration
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical, "the competing public transaction must run outside Critical")
			if this.Mode == "commit" {
				this.Result := PersonalInfoCommitValues(this.Path,
					Map("first_name", "Zoë", "last_name", "Committed"))
				AssertTrue(this.Result is Integer && this.Result == 1,
					"the competing identity must be durably acknowledged by the real writer")
			} else if this.Mode == "read" {
				AssertEqual(1, FSWriteDurable(this.Path, _PIRP_Image("Zoë", "Newer read", false)))
				ReadPersonalInfoToml(this.Path)
				AssertEqual("Zoë", PersonalInformation["first_name"],
					"the nested public reader must admit its actual newer file")
				AssertEqual("last_name", PersonalInformationLetters["q"])
			}
			this.Information := PersonalInformation
			this.Letters := PersonalInformationLetters
			this.Generation := HSE_RuntimeDecisionGeneration
			this.Bytes := FSReadBytesStrict(this.Path)
		} catch as Failure
			this.Failure := Failure
		finally this.Done := true
	}
	Exercise() {
		global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
		global HSE_RuntimeDecisionGeneration
		AssertEqual(1, FSWriteDurable(this.Path, _PIRP_Image("André", "Older parse", true)))
		BeforeGeneration := HSE_RuntimeDecisionGeneration
		LoggerSetTestSink(this.SinkFn)
		ReadPersonalInfoToml(this.Path)
		LoggerClearTestSink()
		if this.Failure is Error
			throw this.Failure
		AssertEqual(1, this.LogCalls, "the real duplicate-alias diagnostic must be observed once")
		AssertEqual(1, this.TimerCalls, "one genuine timer must interrupt the diagnostic")
		if this.Mode == "live" {
			AssertEqual("André", PersonalInformation["first_name"],
				"an uninterrupted reader must still publish its admitted source")
			AssertEqual("Older parse", PersonalInformation["last_name"])
			AssertEqual("first_name", PersonalInformationLetters["p"])
			AssertEqual(1, PersonalInformationLetters.Count,
				"the real duplicate alias must remain ignored")
			AssertEqual(BeforeGeneration, HSE_RuntimeDecisionGeneration)
		} else {
			; Check business state before receipt/cache shape: the old reader really
			; loses the acknowledged identity, rather than lacking a future helper.
			AssertEqual("Zoë", PersonalInformation["first_name"],
				"a returning old parse cannot replace the newer admitted personal identity")
			AssertEqual(this.Mode == "commit" ? "Committed" : "Newer read",
				PersonalInformation["last_name"])
			AssertTrue(PersonalInformation == this.Information,
				"the exact newer information map must remain published")
			AssertTrue(PersonalInformationLetters == this.Letters,
				"the exact newer alias map must remain published")
			AssertEqual(this.Generation, HSE_RuntimeDecisionGeneration)
			AssertEqual(BeforeGeneration + (this.Mode == "commit" ? 1 : 0), this.Generation)
		}
		_PIRP_Bytes(this.Bytes, FSReadBytesStrict(this.Path),
			"finishing the old read must never change the authoritative durable bytes")
		; A subsequent cache hit is a second public observation: stale cache A
		; must not overwrite winner B after the first publication was preserved.
		ReadPersonalInfoToml(this.Path)
		AssertEqual(this.Mode == "live" ? "André" : "Zoë", PersonalInformation["first_name"],
			"the next public read must retain the current durable identity")
		AssertTrue(_ReadPersonalInfoTomlCache is Map)
		_PIRP_Bytes(this.Bytes, _ReadPersonalInfoTomlCache["source"]["bytes"],
			"the published read cache must describe the current file, not the interrupted image")
		Lease := _PersonalTomlWriteLeaseTryAcquire(this.Path, "personal-reader-control")
		AssertTrue(Lease is Object, "the competing transaction must release its exact lease")
		try AssertTrue(_PersonalTomlWriteLeaseOwns(Lease, this.Path))
		finally _PersonalTomlWriteLeaseRelease(Lease)
		Stages := 0
		loop files, this.Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "no private stage may survive the completed transaction")
	}
	Close() {
		SetTimer(this.TimerFn, 0)
		this.TimerFn := 0
		this.SinkFn := 0
	}
}

_PIRP_Image(First, Last, Duplicate) {
	Aliases := Duplicate ? 'p = "first_name"`np = "last_name"`n' : 'q = "last_name"`n'
	return '[info]`nfirst_name = "' . First . '"`nlast_name = "' . Last
		. '"`n`n[letters]`n' . Aliases
}

_PIRP_Bytes(Expected, Actual, Message) {
	AssertTrue(Expected is Buffer && Actual is Buffer, Message)
	AssertEqual(Expected.Size, Actual.Size, Message)
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, Message)
}

_PIRP_Case(Mode) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global ScriptInformation, HSE_RuntimeDecisionGeneration, _TomlUnreadableFiles
	global _PrefixInputHook, _PrefixVisibleFireDecisions, _HealthCheckWarnCount
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	static Sequence := 0
	AssertFalse(A_IsSuspended)
	AssertFalse(_PrefixInputHook)
	AssertTrue(_PrefixVisibleFireDecisions is Array && _PrefixVisibleFireDecisions.Length == 0)
	AssertEqual(0, _LOGGER_TEST_SINK, "the fixture must not replace a foreign log observer")
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive, "a foreign logger flush cannot be detached")
	Saved := {HadInfo: IsSet(PersonalInformation), HadLetters: IsSet(PersonalInformationLetters),
		Cache: _ReadPersonalInfoTomlCache, Generation: HSE_RuntimeDecisionGeneration,
		HadPath: ScriptInformation.Has("PersonalInfoTomlPath"), Path: ScriptInformation.Get("PersonalInfoTomlPath", ""),
		HadWarnings: IsSet(_HealthCheckWarnCount), Repeat: _LOGGER_REPEAT_ENABLED, PathDate: _LOGGER_PATH_DATE}
	Saved.Info := Saved.HadInfo ? PersonalInformation : 0
	Saved.Letters := Saved.HadLetters ? PersonalInformationLetters : 0
	Saved.Warnings := Saved.HadWarnings ? _HealthCheckWarnCount : 0
	Root := A_Temp . "\ergopti_personal_reader_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	Path := Root . "\personal_info.toml"
	FSCreateDirectoryExclusiveStrict(Root)
	F := _PIRP_Fixture(Mode, Path), Primary := 0, CleanupError := 0
	PreviousCritical := A_IsCritical
	try {
		PersonalInformation := Map("first_name", "Seed", "last_name", "Before")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
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
			PersonalInformation := Saved.HadInfo ? Saved.Info : unset
			PersonalInformationLetters := Saved.HadLetters ? Saved.Letters : unset
			_ReadPersonalInfoTomlCache := Saved.Cache
			HSE_RuntimeDecisionGeneration := Saved.Generation
			_HealthCheckWarnCount := Saved.HadWarnings ? Saved.Warnings : unset
			if Saved.HadPath
				ScriptInformation["PersonalInfoTomlPath"] := Saved.Path
			else
				ScriptInformation.Delete("PersonalInfoTomlPath")
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

Test("personal info reader: a newer durable commit survives an interrupted parse (personal-info-reader-publication)",
	_PIRP_Case.Bind("commit"))
Test("personal info reader: a newer public read survives an interrupted parse (personal-info-reader-publication)",
	_PIRP_Case.Bind("read"))
Test("personal info reader: uninterrupted diagnostic still publishes its source (personal-info-reader-publication)",
	_PIRP_Case.Bind("live"))
