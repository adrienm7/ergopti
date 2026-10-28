; tests/unit/infra/toml/test_toml_reader_publication.ahk

; ==============================================================================
; MODULE: TOML Reader Publication Tests
; DESCRIPTION:
; An interrupted old parse may return its detached result, but must not replace
; a newer cached read or completed rewrite consumed by the real timing loader.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TCRP_Fixture {
	__New(Mode, Root) {
		this.Mode := Mode
		this.Root := Root
		this.Path := Root . "\modules\timings\constants.toml"
		this.LogCalls := 0, this.TimerCalls := 0
		this.Done := false, this.Failure := 0
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
	}
	OnLog(Line) {
		if !InStr(Line, "[WARNING] [TomlParse] Unterminated multi-line array", true)
			return
		this.LogCalls += 1
		if this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the actual parse diagnostic must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the real timer must settle before the old diagnostic returns")
		} catch as Failure
			this.Failure := Failure
	}
	OnTimer() {
		global _ParseTomlCache
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical)
			AssertFalse(FileReadActivityBusy(this.Path),
				"the old FileRead is closed before its later parse diagnostic")
			if this.Mode != "live" {
				AssertEqual(1, FSWriteDurable(this.Path, _TCRP_Image(3000, false)))
				this.Winner := ParseTomlFile(this.Path)
				AssertEqual(3000, IniCacheGet(this.Winner, "keylogger", "think_pause_ms"),
					"the actual newer parse must admit the repaired source")
				if this.Mode == "commit" {
					Receipt := TOML_Write(4000, this.Path, "keylogger", "think_pause_ms")
					AssertTrue(Receipt is Integer && Receipt == 1,
						"the public writer must acknowledge a real durable rewrite")
					AssertFalse(_ParseTomlCache.Has(this.Path),
						"the completed writer must really evict the admitted parse")
				}
			}
			this.Bytes := FSReadBytesStrict(this.Path)
		} catch as Failure
			this.Failure := Failure
		finally this.Done := true
	}
	Exercise() {
		global _ParseTomlCache
		AssertEqual(1, FSWriteDurable(this.Path, _TCRP_Image(2000, true)))
		AssertFalse(_ParseTomlCache.Has(this.Path), "the old parse must start uncached")
		LoggerSetTestSink(this.SinkFn)
		Older := ParseTomlFile(this.Path)
		LoggerClearTestSink()
		if this.Failure is Error
			throw this.Failure
		AssertEqual(1, this.LogCalls)
		AssertEqual(1, this.TimerCalls)
		AssertEqual(2000, IniCacheGet(Older, "keylogger", "think_pause_ms"),
			"the old detached result still belongs to its own source image")
		; The genuine consumer resolves the same relative constants path. The
		; original parser fails on the stale effective timing before any proposed
		; generation or helper can manufacture a missing-implementation failure.
		TimingsLoadShared(this.Root)
		Expected := this.Mode == "live" ? 2000 : this.Mode == "commit" ? 4000 : 3000
		AssertEqual(Expected, TimingsGet("keylogger", "think_pause_ms"),
			"a returning old parse cannot replace the timing admitted by a newer reader or writer")
		Current := ParseTomlFile(this.Path)
		if this.Mode == "read"
			AssertTrue(Current == this.Winner, "the exact newer cache object must survive")
		AssertEqual(Expected, IniCacheGet(Current, "keylogger", "think_pause_ms"))
		_TCRP_Bytes(this.Bytes, FSReadBytesStrict(this.Path))
		AssertFalse(FileReadActivityBusy(this.Path))
		AssertFalse(ConfigWriteLeaseBusy())
		Stages := 0
		loop files, this.Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "the real writer cannot leave a stage behind")
	}
	Close() {
		SetTimer(this.TimerFn, 0)
		this.TimerFn := 0, this.SinkFn := 0
	}
}

_TCRP_Image(Value, Broken) {
	return "[keylogger]`nthink_pause_ms = " . Value . "`n"
		. (Broken ? "unfinished = [`n" : "")
}

_TCRP_Bytes(Expected, Actual) {
	AssertTrue(Expected is Buffer && Actual is Buffer)
	AssertEqual(Expected.Size, Actual.Size, "finishing a parse cannot rewrite the admitted source")
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, "the repaired or committed bytes must remain exact")
}

_TCRP_Case(Mode) {
	global _ParseTomlCache, _TomlReadFailures, _TomlUnreadableFiles, _TimingsCache
	global _HealthCheckWarnCount, _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	static Sequence := 0
	AssertFalse(A_IsSuspended)
	AssertEqual(0, _LOGGER_TEST_SINK, "the test cannot replace a foreign logger observer")
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	Saved := {Timings: _TimingsCache, HadWarnings: IsSet(_HealthCheckWarnCount),
		Repeat: _LOGGER_REPEAT_ENABLED, PathDate: _LOGGER_PATH_DATE}
	Saved.Warnings := Saved.HadWarnings ? _HealthCheckWarnCount : 0
	Root := A_Temp . "\ergopti_toml_reader_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	F := _TCRP_Fixture(Mode, Root), Primary := 0, CleanupError := 0
	PreviousCritical := A_IsCritical
	try {
		DirCreate(Root . "\modules\timings")
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := ""
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
			_LOGGER_REPEAT_ENABLED := Saved.Repeat, _LOGGER_PATH_DATE := Saved.PathDate
			_TLOG_RestoreLoggerState(SavedLogger)
			_TimingsCache := Saved.Timings
			_HealthCheckWarnCount := Saved.HadWarnings ? Saved.Warnings : unset
			for Cache in [_ParseTomlCache, _TomlReadFailures, _TomlUnreadableFiles]
				if Cache.Has(F.Path)
					Cache.Delete(F.Path)
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

Test("TOML reader: a newer public read retains effective timings (toml-parser-publication)",
	_TCRP_Case.Bind("read"))
Test("TOML reader: a committed rewrite survives an older parse (toml-parser-publication)",
	_TCRP_Case.Bind("commit"))
Test("TOML reader: an uninterrupted diagnostic retains its timings (toml-parser-publication)",
	_TCRP_Case.Bind("live"))
